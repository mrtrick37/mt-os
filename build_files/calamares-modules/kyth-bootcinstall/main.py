#!/usr/bin/env python3
# kyth-bootcinstall — Calamares Python job module
#
# Uses 'bootc install to-filesystem' so we control partitioning.
# BFQ I/O deadlock prevention relies on elevator=mq-deadline in the kernel
# cmdline (set in build-live-iso.sh) which forces mq-deadline globally before
# any I/O starts, including loop and CD-ROM devices.
#
# Flow:
#   1.  Read target disk from Calamares globalStorage.
#   2.  Unmount whatever the partition module left on the disk.
#   3.  Activate zram swap via sysfs (bypasses unreliable systemd path).
#   4.  Set mq-deadline on all block devices to avoid BFQ I/O deadlocks.
#         Note: the live ISO boot line also passes elevator=mq-deadline so the
#         kernel default is already mq-deadline before the installer runs.
#   5.  Wipe + repartition: EFI 512 MiB (FAT32) + root (rest, XFS)
#   6.  Format + mount root at /mnt/kyth-install.
#   7.  Run 'bootc install to-filesystem' with source from bundled OCI dir
#       (offline) or registry (online).
#   8.  Find the ostree deployment; undo live-session configuration.
#   9.  Bind-mount /proc /sys /dev + var so Calamares user jobs can chroot.
#   10. Update globalStorage for handoff to users/hostname jobs.

import configparser
import glob as _glob
import math
import os
import re
import subprocess
import tempfile
import threading
import time

import libcalamares

# ── Source image resolution ────────────────────────────────────────────────────
_BUNDLED_OCI_DIR   = "/usr/share/kyth/image"
_SOURCE_IMGREF_FILE = "/usr/share/kyth/source-imgref"

if os.path.isdir(_BUNDLED_OCI_DIR):
    _OFFLINE    = True
    SOURCE_IMGREF = f"oci:{_BUNDLED_OCI_DIR}"
else:
    _OFFLINE    = False
    _default_src = "docker://ghcr.io/mrtrick37/kyth:latest"
    try:
        _default_src = open(_SOURCE_IMGREF_FILE).read().strip() or _default_src
    except OSError:
        pass
    SOURCE_IMGREF = os.environ.get("KYTH_SOURCE_IMGREF", _default_src)

TARGET_IMGREF = os.environ.get("KYTH_TARGET_IMGREF", "ghcr.io/mrtrick37/kyth:latest")

# Where we mount the target root during installation.
TARGET_ROOT   = "/mnt/kyth-install"


def pretty_name():
    return "Installing Kyth"


# ── Helpers ───────────────────────────────────────────────────────────────────

def _log(msg):
    libcalamares.utils.debug(f"kyth-bootcinstall: {msg}")


def _run(cmd):
    _log(" ".join(str(c) for c in cmd))
    subprocess.run(cmd, check=True)


STATUS_FILE = "/tmp/kyth-install-progress"


def _write_status(value, label=""):
    try:
        with open(STATUS_FILE, "w") as f:
            f.write(f"{value:.4f}\n{label}\n")
    except OSError:
        pass


def _umount_recursive(path):
    """Best-effort recursive unmount."""
    try:
        subprocess.run(["umount", "-R", path], check=True, capture_output=True)
    except subprocess.CalledProcessError:
        pass


def _find_disk(gs):
    """Return the whole-disk device (e.g. /dev/vda) from globalStorage."""
    disk = (gs.value("installationDevice") or
            gs.value("bootLoaderInstallPath") or "").strip()
    if disk:
        m = re.match(
            r"^(/dev/(?:sd[a-z]+|vd[a-z]+|hd[a-z]+|nvme\d+n\d+))(?:p?\d+)?$",
            disk,
        )
        return m.group(1) if m else disk
    for part in (gs.value("partitions") or []):
        device = part.get("device", "") if isinstance(part, dict) else ""
        m = re.match(
            r"^(/dev/(?:sd[a-z]+|vd[a-z]+|hd[a-z]+|nvme\d+n\d+))(?:p?\d+)?$",
            device,
        )
        if m:
            return m.group(1)
    return ""


def _part(disk, n):
    """Return the nth partition device path.

    /dev/vda  → /dev/vda1, /dev/vda2, …
    /dev/nvme0n1 → /dev/nvme0n1p1, /dev/nvme0n1p2, …
    """
    if re.search(r"(nvme\d+n\d+|loop\d+)$", disk):
        return f"{disk}p{n}"
    return f"{disk}{n}"


def _blkid_uuid(device):
    """Return the filesystem UUID of a block device, or '' on failure."""
    try:
        r = subprocess.run(
            ["blkid", "-s", "UUID", "-o", "value", device],
            capture_output=True, text=True, check=True,
        )
        return r.stdout.strip()
    except subprocess.CalledProcessError:
        return ""


def _set_scheduler(dev_name):
    """Set the I/O scheduler to mq-deadline (or best available) on dev_name."""
    sched_path = f"/sys/block/{dev_name}/queue/scheduler"
    if not os.path.exists(sched_path):
        return
    try:
        with open(sched_path) as f:
            available = f.read()
        for sched in ["mq-deadline", "deadline", "none"]:
            if sched in available:
                with open(sched_path, "w") as f:
                    f.write(sched + "\n")
                _log(f"I/O scheduler: {sched} on {dev_name}")
                return
    except OSError as e:
        _log(f"warning: scheduler on {dev_name}: {e}")


def _setup_zram_swap():
    """Activate zram swap directly via sysfs — more reliable than systemd in live."""
    try:
        subprocess.run(["modprobe", "zram"], check=True, capture_output=True)
        mem_kb = 0
        with open("/proc/meminfo") as f:
            for line in f:
                if line.startswith("MemTotal:"):
                    mem_kb = int(line.split()[1])
                    break
        zram_bytes = min(mem_kb * 1024, 4 * 1024 ** 3)  # min(RAM, 4 GiB)
        with open("/sys/block/zram0/comp_algorithm", "w") as f:
            f.write("zstd\n")
        with open("/sys/block/zram0/disksize", "w") as f:
            f.write(f"{zram_bytes}\n")
        subprocess.run(["mkswap", "/dev/zram0"], check=True, capture_output=True)
        subprocess.run(["swapon", "-p", "100", "/dev/zram0"], check=True, capture_output=True)
        _log(f"zram swap active: {zram_bytes // (1024 ** 2)} MiB")
    except Exception as e:
        _log(f"warning: zram swap setup failed: {e}")


def _find_deployment(mount_root):
    """Walk the ostree deployment tree; return (deployment_dir, var_dir) or (None, None)."""
    deploy_base = os.path.join(mount_root, "ostree", "deploy")
    if not os.path.isdir(deploy_base):
        return None, None
    stateroots = [e for e in os.listdir(deploy_base)
                  if os.path.isdir(os.path.join(deploy_base, e))]
    if not stateroots:
        return None, None
    stateroot  = stateroots[0]
    var_dir    = os.path.join(deploy_base, stateroot, "var")
    deploy_sub = os.path.join(deploy_base, stateroot, "deploy")
    if not os.path.isdir(deploy_sub):
        return None, None
    deploys = [d for d in os.listdir(deploy_sub)
               if not d.endswith(".origin")
               and os.path.isdir(os.path.join(deploy_sub, d))]
    if not deploys:
        return None, None
    deploy_dir = os.path.join(deploy_sub, deploys[0])
    if not os.path.isdir(os.path.join(deploy_dir, "usr")):
        return None, None
    return deploy_dir, var_dir


def _undo_live_config(deploy_dir):
    """Undo live-session-specific configuration in the installed deployment."""
    _log("undoing live-session configuration in deployment")

    # Remove getty autologin drop-in.
    getty_drop_in = os.path.join(
        deploy_dir, "etc/systemd/system/getty@tty1.service.d/autologin.conf"
    )
    try:
        os.remove(getty_drop_in)
        _log("removed getty@tty1 autologin")
    except FileNotFoundError:
        pass

    # Remove live I/O scheduler udev rule.
    live_io_rule = os.path.join(deploy_dir, "etc/udev/rules.d/61-live-ioschedulers.rules")
    try:
        os.remove(live_io_rule)
    except FileNotFoundError:
        pass

    # Set graphical.target as default.
    default_target = os.path.join(deploy_dir, "etc/systemd/system/default.target")
    try:
        os.remove(default_target)
    except FileNotFoundError:
        pass
    os.symlink("/usr/lib/systemd/system/graphical.target", default_target)
    _log("default.target → graphical.target")

    # Enable SDDM.
    wants_dir = os.path.join(deploy_dir, "etc/systemd/system/graphical.target.wants")
    os.makedirs(wants_dir, exist_ok=True)
    sddm_link = os.path.join(wants_dir, "sddm.service")
    if not os.path.lexists(sddm_link):
        os.symlink("/usr/lib/systemd/system/sddm.service", sddm_link)
        _log("enabled sddm.service")

    # Update /etc/sddm.conf: clear autologin, hide liveuser.
    sddm_conf_path = os.path.join(deploy_dir, "etc/sddm.conf")
    if os.path.exists(sddm_conf_path):
        cfg = configparser.RawConfigParser()
        cfg.optionxform = str
        cfg.read(sddm_conf_path)
        if cfg.has_section("Autologin"):
            cfg.set("Autologin", "User", "")
            cfg.set("Autologin", "Relogin", "false")
        if not cfg.has_section("Users"):
            cfg.add_section("Users")
        existing = cfg.get("Users", "HideUsers", fallback="")
        hidden   = [u.strip() for u in existing.split(",") if u.strip()]
        if "liveuser" not in hidden:
            hidden.append("liveuser")
        cfg.set("Users", "HideUsers", ",".join(hidden))
        with open(sddm_conf_path, "w") as f:
            cfg.write(f)
        _log("sddm.conf updated")


# ── Main job ──────────────────────────────────────────────────────────────────

def run():
    gs = libcalamares.globalstorage

    # ── 1. Resolve target disk ───────────────────────────────────────────────
    disk = _find_disk(gs)
    if not disk:
        return (
            "Installation error",
            "Could not determine the target disk.\n"
            "Please go back and select a disk, then try again.",
        )

    old_root_mount = (gs.value("rootMountPoint") or "/tmp/calamares-root").rstrip("/")
    _log(f"target disk: {disk}  old rootMountPoint: {old_root_mount}")

    # ── 2. Release partition module mounts ───────────────────────────────────
    _write_status(0.0, "Unmounting temporary partitions…")
    _umount_recursive(old_root_mount)
    try:
        lsblk = subprocess.run(
            ["lsblk", "-n", "-o", "MOUNTPOINT", disk],
            capture_output=True, text=True, check=True,
        )
        for mp in lsblk.stdout.splitlines():
            mp = mp.strip()
            if mp and mp != "[SWAP]":
                _umount_recursive(mp)
        subprocess.run(["swapoff", "--all"], capture_output=True)
    except subprocess.CalledProcessError as e:
        _log(f"warning: lsblk/swapoff: {e}")

    # ── 3. Zram swap (direct sysfs — bypasses unreliable systemd path) ───────
    _write_status(0.01, "Setting up swap…")
    _setup_zram_swap()

    # ── 4. Log memory state ──────────────────────────────────────────────────
    try:
        with open("/proc/meminfo") as mf:
            for line in mf:
                if any(k in line for k in ("MemTotal", "MemAvailable", "SwapTotal", "SwapFree")):
                    _log(f"mem: {line.strip()}")
    except OSError:
        pass

    # ── 5. Drop page cache ───────────────────────────────────────────────────
    try:
        subprocess.run(["sync"], capture_output=True)
        with open("/proc/sys/vm/drop_caches", "w") as f:
            f.write("3\n")
    except OSError:
        pass

    # ── 6. I/O schedulers — belt-and-suspenders BFQ prevention ──────────────
    # The live ISO kernel cmdline passes elevator=mq-deadline which sets the
    # default at boot.  We also set it explicitly via sysfs here in case any
    # device registered after the kernel boot parameter was applied, or in case
    # the parameter was not effective for a specific device class.
    _set_scheduler(os.path.basename(disk))
    for p in _glob.glob("/sys/block/loop*/queue/scheduler"):
        _set_scheduler(os.path.basename(os.path.dirname(os.path.dirname(p))))
    for p in _glob.glob("/sys/block/nvme*/queue/scheduler"):
        _set_scheduler(os.path.basename(os.path.dirname(os.path.dirname(p))))
    for p in _glob.glob("/sys/block/sr*/queue/scheduler"):
        _set_scheduler(os.path.basename(os.path.dirname(os.path.dirname(p))))

    # ── 7. Wipe disk ─────────────────────────────────────────────────────────
    _write_status(0.02, "Wiping existing partition table…")
    for cmd in (
        ["blkdiscard", "-f", disk],
        ["sgdisk", "--zap-all", disk],
        ["wipefs", "-a", "--force", disk],
        ["partprobe", disk],
        ["udevadm", "settle"],
    ):
        try:
            subprocess.run(cmd, check=True, capture_output=True)
        except (subprocess.CalledProcessError, FileNotFoundError) as e:
            _log(f"warning: {cmd[0]}: {e}")

    # ── 8. Partition disk ─────────────────────────────────────────────────────
    # Two partitions: EFI 512 MiB (FAT32) + root (rest, XFS).
    # BFQ deadlock prevention is handled globally by elevator=mq-deadline on
    # the kernel cmdline, so no staging partition is needed.
    _write_status(0.04, "Partitioning disk…")
    _log(f"partitioning {disk}: EFI 512 MiB + XFS root")
    sfdisk_input = "label: gpt\n, 512M, U\n, , L\n"
    subprocess.run(
        ["sfdisk", "--no-reread", "--force", disk],
        input=sfdisk_input.encode(),
        check=True, capture_output=True,
    )
    subprocess.run(["partprobe", disk], capture_output=True)
    subprocess.run(["udevadm", "settle"], capture_output=True)

    efi_part  = _part(disk, 1)
    root_part = _part(disk, 2)
    _log(f"EFI: {efi_part}  root: {root_part}")

    # ── 9. Format partitions ─────────────────────────────────────────────────
    _write_status(0.06, "Formatting partitions…")
    subprocess.run(["mkfs.fat", "-F32", "-n", "EFI", efi_part],
                   check=True, capture_output=True)
    subprocess.run(["mkfs.xfs", "-f", root_part],
                   check=True, capture_output=True)
    subprocess.run(["udevadm", "settle"], capture_output=True)

    root_uuid = _blkid_uuid(root_part)
    efi_uuid  = _blkid_uuid(efi_part)
    _log(f"root UUID={root_uuid}  EFI UUID={efi_uuid}")

    # ── 10. Mount target root only ────────────────────────────────────────────
    # bootc install to-filesystem requires an empty target (or one containing
    # only mount points).  Do NOT pre-create directories — bootc auto-discovers
    # the ESP on the same disk and mounts it internally.
    _write_status(0.07, "Mounting target filesystem…")
    os.makedirs(TARGET_ROOT, exist_ok=True)
    try:
        _run(["mount", root_part, TARGET_ROOT])
    except subprocess.CalledProcessError:
        return ("Installation error", f"Could not mount {root_part} at {TARGET_ROOT}.")

    # ── 11. Pre-flight ───────────────────────────────────────────────────────
    if _OFFLINE and not os.path.isdir(_BUNDLED_OCI_DIR):
        _umount_recursive(TARGET_ROOT)
        return (
            "Installation error",
            f"Bundled OS image not found at {_BUNDLED_OCI_DIR}.\n"
            "The live ISO may be incomplete.",
        )

    # Create a tmp dir on the target disk so bootc writes temp files there
    # instead of to the in-RAM tmpfs.  This keeps memory pressure low during
    # layer extraction, which is the most common cause of the install freeze.
    _target_tmp = os.path.join(TARGET_ROOT, "tmp")
    os.makedirs(_target_tmp, exist_ok=True)

    # Tune VM memory management to prevent memory-pressure stalls.
    # swappiness=200 starts swapping very early; vfs_cache_pressure=500 frees
    # dentry/inode caches aggressively so the OCI layer reader can get pages.
    for _path, _val in [
        ("/proc/sys/vm/swappiness",            "200"),
        ("/proc/sys/vm/vfs_cache_pressure",    "500"),
        ("/proc/sys/vm/dirty_ratio",           "5"),
        ("/proc/sys/vm/dirty_background_ratio","2"),
    ]:
        try:
            with open(_path, "w") as _f:
                _f.write(_val + "\n")
        except OSError:
            pass

    libcalamares.job.setprogress(0.08)

    # ── 12. Time-based progress thread ───────────────────────────────────────
    _stop_event = threading.Event()

    if _OFFLINE:
        PHASE_LABELS = [
            (0.00, "Installing OS — this takes a few minutes…"),
            (0.10, "Extracting OS image…"),
            (0.55, "Writing filesystem layers…"),
            (0.82, "Committing ostree deployment…"),
            (0.93, "Installing bootloader…"),
            (0.97, "Finalizing…"),
        ]
        HALF_TIME = 300
    else:
        PHASE_LABELS = [
            (0.00, "Connecting to registry…"),
            (0.05, "Downloading OS image — this may take 10-20 minutes…"),
            (0.60, "Writing filesystem layers…"),
            (0.82, "Committing ostree deployment…"),
            (0.93, "Installing bootloader…"),
            (0.97, "Finalizing…"),
        ]
        HALF_TIME = 360

    def _progress_thread():
        TARGET_VAL = 0.88
        start      = time.monotonic()
        last_label = ""
        while not _stop_event.is_set():
            elapsed  = time.monotonic() - start
            k        = math.log(2) / HALF_TIME
            value    = min(TARGET_VAL * (1.0 - math.exp(-k * elapsed)), TARGET_VAL)
            libcalamares.job.setprogress(value)
            fraction = value / TARGET_VAL
            label    = PHASE_LABELS[0][1]
            for threshold, lbl in PHASE_LABELS:
                if fraction >= threshold:
                    label = lbl
            if label != last_label:
                _log(f"status: {label}")
                last_label = label
            _write_status(fraction, label)
            time.sleep(1.5)

    t = threading.Thread(target=_progress_thread, daemon=True)
    t.start()

    _log(f"source: {SOURCE_IMGREF}  target-imgref: {TARGET_IMGREF}")

    # ── 14. Run bootc install to-filesystem ──────────────────────────────────
    log_fd, log_path = tempfile.mkstemp(prefix="bootc-install.", suffix=".log")
    os.close(log_fd)
    _log(f"bootc output log: {log_path}")

    # nice -n 10: lower CPU priority so KDE/VNC stays responsive during install.
    bootc_cmd = [
        "nice", "-n", "10",
        "bootc", "install", "to-filesystem",
        "--source-imgref", SOURCE_IMGREF,
        "--target-imgref", TARGET_IMGREF,
    ]
    if root_uuid:
        bootc_cmd += ["--root-mount-spec", f"UUID={root_uuid}"]
    if _OFFLINE:
        bootc_cmd.append("--skip-fetch-check")
    bootc_cmd.append(TARGET_ROOT)

    try:
        with open(log_path, "w") as log_fh:
            # Stream bootc output to both the log file and the Calamares debug
            # log in real time.  This lets you see exactly where bootc was when
            # the VM appeared to freeze (check journalctl or calamares.log).
            with subprocess.Popen(
                bootc_cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                env={**os.environ, "TMPDIR": _target_tmp},
            ) as proc:
                for line in proc.stdout:
                    log_fh.write(line)
                    log_fh.flush()
                    _log(f"bootc: {line.rstrip()}")
                proc.wait()
            if proc.returncode != 0:
                raise subprocess.CalledProcessError(proc.returncode, bootc_cmd)
    except subprocess.CalledProcessError as e:
        _stop_event.set()
        try:
            with open(log_path) as lf:
                detail = lf.read().strip()
        except OSError:
            detail = ""
        _log(f"bootc exit {e.returncode}: {detail!r}")
        _umount_recursive(TARGET_ROOT)
        return (
            "Installation failed",
            f"bootc install to-filesystem failed (exit {e.returncode}).\n\n"
            + (detail or f"No output captured. Check {log_path} and journalctl."),
        )
    finally:
        _stop_event.set()

    _write_status(1.0, "Image written — locating installed system…")
    libcalamares.job.setprogress(0.90)

    # ── 15. Find ostree deployment ────────────────────────────────────────────
    deploy_dir, var_dir = _find_deployment(TARGET_ROOT)
    if not deploy_dir:
        _umount_recursive(TARGET_ROOT)
        return (
            "Post-install error",
            f"Could not locate the ostree deployment under {TARGET_ROOT}.\n"
            "The OS was installed but user configuration was not applied.",
        )

    _log(f"deployment: {deploy_dir}")
    _log(f"var dir:    {var_dir}")

    # ── 16. Undo live-session configuration ───────────────────────────────────
    _write_status(1.0, "Configuring installed system…")
    _undo_live_config(deploy_dir)

    # ── 17. Bind-mount pseudo-filesystems for Calamares user jobs ─────────────
    _write_status(1.0, "Preparing system for user configuration…")
    for sub, src in [("proc", "/proc"), ("sys", "/sys"), ("dev", "/dev")]:
        _run(["mount", "--bind", src, os.path.join(deploy_dir, sub)])
    if var_dir and os.path.isdir(var_dir):
        _run(["mount", "--bind", var_dir, os.path.join(deploy_dir, "var")])

    # ── 18. Hand off to Calamares users/hostname exec jobs ────────────────────
    gs.insert("rootMountPoint",  deploy_dir)
    gs.insert("kyth_outer_mount", TARGET_ROOT)

    _log(f"rootMountPoint  → {deploy_dir}")
    _log(f"kyth_outer_mount → {TARGET_ROOT}")

    libcalamares.job.setprogress(1.0)
    return None
