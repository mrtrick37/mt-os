#!/usr/bin/env python3
# kyth-bootcinstall — Calamares Python job module
#
# Scripted front-end role: this module is the "script" in the scripted
# front-end strategy.  Calamares collected the target disk and user details
# from the user; now this module does all actual disk work.
#
# Steps:
#   1. Read the target disk from globalStorage (set by the partition module's
#      FillGlobalStorageJob).
#   2. Unmount whatever the partition module mounted under rootMountPoint —
#      bootc needs an unmounted disk so it can wipe and repartition it.
#   3. Run `bootc install to-disk` to write the OS image to disk.
#   4. Find the Linux root partition that bootc created.
#   5. Mount the root partition and locate the ostree deployment inside it.
#   6. Bind-mount /proc /sys /dev and the stateroot /var into the deployment
#      directory so that the Calamares users exec jobs (CreateUserJob,
#      SetPasswordJob, SetHostnameJob) can safely chroot into it.
#   7. Update globalStorage:
#        rootMountPoint  → deployment directory  (users exec jobs read this)
#        kyth_outer_mount → outer temp mount dir (kyth-umount reads this)
#
# After this module returns, Calamares runs the standard `users` exec jobs
# (which chroot into rootMountPoint to create the user account and write the
# hostname), then `kyth-umount` cleans up the mounts.

import configparser
import math
import os
import re
import subprocess
import tempfile
import threading
import time

import libcalamares

# ── Source image resolution ────────────────────────────────────────────────────
# Offline ISO:  /usr/share/kyth/image is a bundled OCI directory — no internet.
# Netinstall ISO: /usr/share/kyth/source-imgref holds the registry URL to pull.
# Fallback: pull from the default registry ref (should rarely be needed).
_BUNDLED_OCI_DIR  = "/usr/share/kyth/image"
_SOURCE_IMGREF_FILE = "/usr/share/kyth/source-imgref"

if os.path.isdir(_BUNDLED_OCI_DIR):
    _OFFLINE = True
    SOURCE_IMGREF = f"oci:{_BUNDLED_OCI_DIR}"
else:
    _OFFLINE = False
    _default_src = "docker://ghcr.io/mrtrick37/kyth:latest"
    try:
        _default_src = open(_SOURCE_IMGREF_FILE).read().strip() or _default_src
    except OSError:
        pass
    SOURCE_IMGREF = os.environ.get("KYTH_SOURCE_IMGREF", _default_src)

# Target image: the registry ref written into the installed OS so that
# `bootc upgrade` knows where to pull future updates from.
# Override with KYTH_TARGET_IMGREF env var to test forks or dev images.
TARGET_IMGREF = os.environ.get("KYTH_TARGET_IMGREF", "docker://ghcr.io/mrtrick37/kyth:latest")

# Partition type GUIDs that bootc uses for the root partition.
# bootc creates "Linux root (x86-64)" (4f68...) on modern installs;
# the generic "Linux filesystem data" (0fc6...) is kept as a fallback.
ROOT_PART_GUIDS = {
    "4f68bce3-e8cd-4db1-96e7-fbcaf984b709",  # Linux root (x86-64)
    "0fc63daf-8483-4772-8e79-3d69d8477de4",  # Linux filesystem data
}


def pretty_name():
    return "Installing Kyth"


# ── Helpers ───────────────────────────────────────────────────────────────────

def _log(msg):
    libcalamares.utils.debug(f"kyth-bootcinstall: {msg}")


def _run(cmd):
    _log(" ".join(str(c) for c in cmd))
    subprocess.run(cmd, check=True)


# Status file polled by show.qml to display live install progress.
STATUS_FILE = "/tmp/kyth-install-progress"


def _write_status(value, label=""):
    try:
        with open(STATUS_FILE, "w") as f:
            f.write(f"{value:.4f}\n{label}\n")
    except OSError:
        pass


def _umount_recursive(path):
    """Best-effort recursive unmount — ignores errors if nothing is mounted."""
    try:
        subprocess.run(["umount", "-R", path], check=True, capture_output=True)
    except subprocess.CalledProcessError:
        pass


def _find_disk(gs):
    """
    Return the whole-disk device (e.g. /dev/sda) from globalStorage.

    The partition module's FillGlobalStorageJob writes bootLoaderInstallPath.
    On UEFI systems this is the disk device; on some configs it may be the EFI
    partition — strip the partition suffix to get the bare disk.
    Falls back to deriving from the `partitions` list.
    """
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


def _find_root_partition(disk):
    """Return the device path of the Linux root partition bootc created."""
    # Let udev finish processing the new partition table before querying.
    subprocess.run(["udevadm", "settle"], capture_output=True)

    result = subprocess.run(
        ["lsblk", "-ln", "-o", "NAME,PARTTYPE,FSTYPE", disk],
        capture_output=True, text=True, check=True,
    )
    _log(f"lsblk output:\n{result.stdout}")

    root_part = ""
    for line in result.stdout.splitlines():
        cols = line.split()
        name = cols[0] if len(cols) >= 1 else ""
        parttype = cols[1].lower() if len(cols) >= 2 else ""
        fstype = cols[2].lower() if len(cols) >= 3 else ""

        if parttype in ROOT_PART_GUIDS:
            root_part = f"/dev/{name}"
            break

        # Fallback: btrfs partition is the root (bootc formats it btrfs)
        if fstype == "btrfs" and not root_part:
            root_part = f"/dev/{name}"

    _log(f"root partition: {root_part!r}")
    return root_part


def _find_deployment(mount_root):
    """
    Walk the ostree deployment tree under mount_root and return
    (deployment_dir, var_dir) or (None, None) on failure.
    """
    deploy_base = os.path.join(mount_root, "ostree", "deploy")
    if not os.path.isdir(deploy_base):
        return None, None

    stateroots = [
        e for e in os.listdir(deploy_base)
        if os.path.isdir(os.path.join(deploy_base, e))
    ]
    if not stateroots:
        return None, None

    stateroot = stateroots[0]
    var_dir = os.path.join(deploy_base, stateroot, "var")

    deploy_sub = os.path.join(deploy_base, stateroot, "deploy")
    if not os.path.isdir(deploy_sub):
        return None, None

    deploys = [
        d for d in os.listdir(deploy_sub)
        if not d.endswith(".origin")
        and os.path.isdir(os.path.join(deploy_sub, d))
    ]
    if not deploys:
        return None, None

    deploy_dir = os.path.join(deploy_sub, deploys[0])
    if not os.path.isdir(os.path.join(deploy_dir, "usr")):
        return None, None

    return deploy_dir, var_dir


# ── Post-install live config cleanup ─────────────────────────────────────────

def _undo_live_config(deploy_dir):
    """
    Undo live-session-specific configuration in the installed deployment.

    The live image ships with SDDM disabled, multi-user.target as default,
    and getty@tty1 autologin for liveuser.  After bootc installs the image
    to disk those settings persist verbatim.  This function rewrites the
    deployed /etc so the installed system boots to SDDM with only the
    newly created user visible.
    """
    _log("undoing live-session configuration in deployment")

    # 1. Remove getty autologin drop-in.
    getty_drop_in = os.path.join(
        deploy_dir, "etc/systemd/system/getty@tty1.service.d/autologin.conf"
    )
    try:
        os.remove(getty_drop_in)
        _log("removed getty@tty1 autologin drop-in")
    except FileNotFoundError:
        _log("getty autologin drop-in not found (already absent)")

    # 2. Set graphical.target as the default.
    default_target = os.path.join(deploy_dir, "etc/systemd/system/default.target")
    try:
        os.remove(default_target)
    except FileNotFoundError:
        pass
    os.symlink("/usr/lib/systemd/system/graphical.target", default_target)
    _log("default.target → graphical.target")

    # 3. Enable SDDM by creating the wants symlink (systemctl disable removed it).
    wants_dir = os.path.join(deploy_dir, "etc/systemd/system/graphical.target.wants")
    os.makedirs(wants_dir, exist_ok=True)
    sddm_link = os.path.join(wants_dir, "sddm.service")
    if not os.path.lexists(sddm_link):
        os.symlink("/usr/lib/systemd/system/sddm.service", sddm_link)
        _log("enabled sddm.service")

    # 4. Update /etc/sddm.conf: clear autologin user, hide liveuser.
    sddm_conf_path = os.path.join(deploy_dir, "etc/sddm.conf")
    if os.path.exists(sddm_conf_path):
        cfg = configparser.RawConfigParser()
        cfg.optionxform = str  # preserve key case (SDDM is case-sensitive)
        cfg.read(sddm_conf_path)

        if cfg.has_section("Autologin"):
            cfg.set("Autologin", "User", "")
            cfg.set("Autologin", "Relogin", "false")

        if not cfg.has_section("Users"):
            cfg.add_section("Users")
        existing = cfg.get("Users", "HideUsers", fallback="")
        hidden = [u.strip() for u in existing.split(",") if u.strip()]
        if "liveuser" not in hidden:
            hidden.append("liveuser")
        cfg.set("Users", "HideUsers", ",".join(hidden))

        with open(sddm_conf_path, "w") as f:
            cfg.write(f)
        _log("sddm.conf: cleared autologin, added liveuser to HideUsers")
    else:
        _log("sddm.conf not found — skipping SDDM config update")


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

    # ── 2. Release the partition module's mounts ─────────────────────────────
    # The partition exec jobs formatted the disk and mounted it under
    # rootMountPoint.  Unmount everything so bootc can wipe the disk.
    _write_status(0.0, "Unmounting temporary partitions…")
    _log("unmounting partition module mounts")
    _umount_recursive(old_root_mount)

    # Also unmount any other partitions of the target disk that may be mounted
    # (e.g. swap, EFI) — the partition module may have mounted more than rootMountPoint.
    _log(f"unmounting any remaining mounts on {disk}")
    try:
        lsblk = subprocess.run(
            ["lsblk", "-n", "-o", "MOUNTPOINT", disk],
            capture_output=True, text=True, check=True,
        )
        for mp in lsblk.stdout.splitlines():
            mp = mp.strip()
            if mp and mp != "[SWAP]":
                _umount_recursive(mp)
        # Deactivate swap partitions on the disk
        subprocess.run(["swapoff", "--all"], capture_output=True)
    except subprocess.CalledProcessError as e:
        _log(f"warning: lsblk/swapoff failed (non-fatal): {e}")

    # ── 3. Run bootc install to-disk ─────────────────────────────────────────
    # The Calamares partition exec job already formatted the disk before this
    # module runs.  Destroy its partition table and filesystem signatures so
    # bootc sees a completely blank disk and creates its own layout from scratch.
    _write_status(0.0, "Wiping existing partition table…")
    _log(f"zapping partition table on {disk}")
    for cmd in (
        ["sgdisk", "--zap-all", disk],   # destroy GPT + MBR partition tables
        ["wipefs", "-a", disk],           # remove any remaining filesystem signatures
        ["partprobe", disk],              # tell the kernel to reread the (now empty) table
        ["udevadm", "settle"],            # wait for udev to finish processing events
    ):
        try:
            subprocess.run(cmd, check=True, capture_output=True)
        except (subprocess.CalledProcessError, FileNotFoundError) as e:
            _log(f"warning: {cmd[0]} failed (non-fatal): {e}")  # bootc will fail clearly if disk is unusable

    # Pre-flight: confirm source image is available.
    if _OFFLINE:
        if not os.path.isdir(_BUNDLED_OCI_DIR):
            return (
                "Installation error",
                f"Bundled OS image not found at {_BUNDLED_OCI_DIR}.\n"
                "The live ISO may be incomplete.",
            )
        _log(f"offline mode: source image at {_BUNDLED_OCI_DIR}")
    else:
        _log(f"network mode: will pull {SOURCE_IMGREF}")

    _log(f"running: bootc install to-disk {disk}")
    libcalamares.job.setprogress(0.03)

    log_fd, log_path = tempfile.mkstemp(prefix="bootc-install.", suffix=".log")
    os.close(log_fd)
    _log(f"bootc output log: {log_path}")

    # ── Time-based progress thread ─────────────────────────────────────────────
    # bootc block-buffers stdout when piped, so log lines arrive only at the end.
    # Instead, drive the Calamares progress bar from elapsed time using an
    # asymptotic curve: fast early movement that slows as it approaches 0.88.
    # Phase labels are written to STATUS_FILE so show.qml can display them.
    _stop_event = threading.Event()

    # Labels shown in the installer UI, keyed by fraction of bootc progress (0→1).
    if _OFFLINE:
        BOOTC_PHASE_LABELS = [
            (0.00, "Starting OS image installation…"),
            (0.05, "Partitioning and formatting disk…"),
            (0.12, "Extracting OS image — this takes a few minutes…"),
            (0.50, "Writing filesystem layers…"),
            (0.72, "Committing ostree deployment…"),
            (0.84, "Installing bootloader…"),
            (0.95, "Finalizing image write…"),
        ]
        HALF_TIME = 120   # offline install ~4 min typical
    else:
        BOOTC_PHASE_LABELS = [
            (0.00, "Connecting to registry…"),
            (0.05, "Downloading OS image — this may take 10-20 minutes…"),
            (0.60, "Writing filesystem layers…"),
            (0.78, "Committing ostree deployment…"),
            (0.88, "Installing bootloader…"),
            (0.95, "Finalizing…"),
        ]
        HALF_TIME = 360   # network install ~12 min typical on average connection

    def _progress_thread():
        TARGET    = 0.88   # leave 0.88→1.0 for mount/chroot steps
        start     = time.monotonic()
        last_label = ""
        while not _stop_event.is_set():
            elapsed  = time.monotonic() - start
            k        = math.log(2) / HALF_TIME
            value    = TARGET * (1.0 - math.exp(-k * elapsed))
            value    = min(value, TARGET)
            libcalamares.job.setprogress(value)
            fraction = value / TARGET   # 0→1 for QML
            label = BOOTC_PHASE_LABELS[0][1]
            for threshold, lbl in BOOTC_PHASE_LABELS:
                if fraction >= threshold:
                    label = lbl
            if label != last_label:
                _log(f"status: {label}")
                last_label = label
            _write_status(fraction, label)
            time.sleep(1.5)

    t = threading.Thread(target=_progress_thread, daemon=True)
    t.start()

    try:
        with open(log_path, "w") as log_fh:
            bootc_cmd = [
                # Run bootc at low I/O priority (best-effort class 7) and low
                # CPU nice so the live session stays responsive during the pull.
                "ionice", "-c", "2", "-n", "7",
                "nice", "-n", "10",
                "bootc", "install", "to-disk",
                "--source-imgref", SOURCE_IMGREF,
                "--target-imgref", TARGET_IMGREF,
                "--filesystem", "btrfs",
            ]
            if _OFFLINE:
                bootc_cmd.append("--skip-fetch-check")
            bootc_cmd.append(disk)

            result = subprocess.run(
                bootc_cmd,
                check=True,
                stdout=log_fh,
                stderr=subprocess.STDOUT,
                env={**os.environ, "TMPDIR": "/var/tmp"},
            )
    except subprocess.CalledProcessError as e:
        _stop_event.set()
        try:
            with open(log_path) as lf:
                detail = lf.read().strip()
        except OSError:
            detail = ""
        _log(f"bootc exit code: {e.returncode}")
        _log(f"bootc output: {detail!r}")
        body = detail if detail else f"No output captured. Check {log_path} and journalctl for details."
        return (
            "Installation failed",
            f"bootc install to-disk failed (exit code {e.returncode}).\n\n{body}",
        )
    finally:
        _stop_event.set()

    _write_status(1.0, "Image written — locating installed system…")
    libcalamares.job.setprogress(0.90)

    # ── 4. Find the root partition bootc created ──────────────────────────────
    _log("locating root partition")
    root_part = _find_root_partition(disk)
    if not root_part:
        return (
            "Post-install error",
            f"Could not find the Linux root partition on {disk} after bootc completed.\n"
            "The OS was installed but user configuration was not applied.",
        )

    # ── 5. Mount root partition + locate ostree deployment ───────────────────
    _write_status(1.0, "Mounting installed system…")
    outer_mount = tempfile.mkdtemp(prefix="kyth-root.")
    try:
        _run(["mount", root_part, outer_mount])
    except subprocess.CalledProcessError:
        os.rmdir(outer_mount)
        return (
            "Post-install error",
            f"Could not mount {root_part}.",
        )

    deploy_dir, var_dir = _find_deployment(outer_mount)
    if not deploy_dir:
        _umount_recursive(outer_mount)
        os.rmdir(outer_mount)
        return (
            "Post-install error",
            "Could not locate the ostree deployment in the installed system.\n"
            "The OS was installed but user configuration was not applied.",
        )

    _log(f"deployment: {deploy_dir}")
    _log(f"var dir:    {var_dir}")

    # ── 5.5. Undo live-session configuration ─────────────────────────────────
    _undo_live_config(deploy_dir)

    # ── 6. Bind-mount pseudo-filesystems into the deployment ─────────────────
    # Required for the Calamares users exec jobs (CreateUserJob, SetPasswordJob,
    # SetHostnameJob) to chroot successfully into the deployment.
    _write_status(1.0, "Preparing system for user configuration…")
    for sub, src in [("proc", "/proc"), ("sys", "/sys"), ("dev", "/dev")]:
        _run(["mount", "--bind", src, os.path.join(deploy_dir, sub)])

    if var_dir and os.path.isdir(var_dir):
        # Bind the stateroot var over the deployment's /var symlink so that
        # `useradd -m` creates the home directory in the right place.
        _run(["mount", "--bind", var_dir, os.path.join(deploy_dir, "var")])

    # ── 7. Hand off to Calamares users exec jobs ─────────────────────────────
    # Update rootMountPoint to the deployment directory.  The standard
    # CreateUserJob / SetPasswordJob / SetHostnameJob chroot here.
    # kyth-umount will clean up outer_mount (and everything under it) when done.
    gs.insert("rootMountPoint", deploy_dir)
    gs.insert("kyth_outer_mount", outer_mount)

    _log(f"rootMountPoint → {deploy_dir}")
    _log(f"kyth_outer_mount → {outer_mount}")

    libcalamares.job.setprogress(1.0)
    return None
