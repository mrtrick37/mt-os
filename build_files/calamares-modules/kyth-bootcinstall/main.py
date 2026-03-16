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

import math
import os
import re
import subprocess
import tempfile
import threading
import time

import libcalamares

# Source image: bundled inside the live squashfs at boot time.
# At live boot this path is read-only inside the squashfs overlay.
# bootc reads it as an OCI directory without requiring internet access.
BUNDLED_IMGREF = "oci:/usr/share/kyth/image"

# Target image: the registry ref written into the installed OS so that
# `bootc upgrade` knows where to pull future updates from.
TARGET_IMGREF = "ghcr.io/mrtrick37/kyth:latest"

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
    disk = (gs.value("bootLoaderInstallPath") or "").strip()

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

        # Fallback: largest xfs partition is the root (bootc always formats it xfs)
        if fstype == "xfs" and not root_part:
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
    except subprocess.CalledProcessError:
        pass

    # ── 3. Run bootc install to-disk ─────────────────────────────────────────
    # The Calamares partition exec job already formatted the disk before this
    # module runs.  Destroy its partition table and filesystem signatures so
    # bootc sees a completely blank disk and creates its own layout from scratch.
    _log(f"zapping partition table on {disk}")
    for cmd in (
        ["sgdisk", "--zap-all", disk],   # destroy GPT + MBR partition tables
        ["wipefs", "-a", disk],           # remove any remaining filesystem signatures
        ["partprobe", disk],              # tell the kernel to reread the (now empty) table
        ["udevadm", "settle"],            # wait for udev to finish processing events
    ):
        try:
            subprocess.run(cmd, check=True, capture_output=True)
        except (subprocess.CalledProcessError, FileNotFoundError):
            pass  # best-effort; bootc will fail with a clear error if disk is unusable

    # Pre-flight: confirm the bundled OCI image directory exists.
    imgref_path = BUNDLED_IMGREF.removeprefix("oci:")
    if not os.path.isdir(imgref_path):
        return (
            "Installation error",
            f"Bundled OS image not found at {imgref_path}.\n"
            "The live ISO may be incomplete.",
        )
    _log(f"source image confirmed at {imgref_path}")

    _log(f"running: bootc install to-disk {disk}")
    libcalamares.job.setprogress(0.03)

    log_fd, log_path = tempfile.mkstemp(prefix="bootc-install.", suffix=".log")
    os.close(log_fd)
    _log(f"bootc output log: {log_path}")

    # Status file read by show.qml to drive the sub-progress bar.
    STATUS_FILE = "/tmp/kyth-install-progress"

    def _write_status(value, label=""):
        try:
            with open(STATUS_FILE, "w") as f:
                f.write(f"{value:.4f}\n{label}\n")
        except OSError:
            pass

    # ── Time-based progress thread ─────────────────────────────────────────────
    # bootc block-buffers stdout when piped, so log lines arrive only at the end.
    # Instead, drive the Calamares progress bar from elapsed time using an
    # asymptotic curve: fast early movement that slows as it approaches 0.88.
    # The thread writes the same value to STATUS_FILE so the QML sub-bar can
    # read it without needing sysfs access.
    _stop_event = threading.Event()

    def _progress_thread():
        TARGET    = 0.88   # leave 0.88→1.0 for mount/chroot steps
        HALF_TIME = 120    # seconds to reach 50% of TARGET (typical install ~4 min)
        start     = time.monotonic()
        while not _stop_event.is_set():
            elapsed  = time.monotonic() - start
            # Exponential approach: progress = TARGET * (1 - e^(-k*t))
            k        = math.log(2) / HALF_TIME
            value    = TARGET * (1.0 - math.exp(-k * elapsed))
            value    = min(value, TARGET)
            libcalamares.job.setprogress(value)
            _write_status(value / TARGET)   # 0→1 fraction for QML
            time.sleep(1.5)

    t = threading.Thread(target=_progress_thread, daemon=True)
    t.start()

    try:
        with open(log_path, "w") as log_fh:
            result = subprocess.run(
                [
                    "bootc", "install", "to-disk",
                    "--source-imgref", BUNDLED_IMGREF,
                    "--target-imgref", TARGET_IMGREF,
                    "--filesystem", "xfs",
                    "--skip-fetch-check",
                    disk,
                ],
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

    _write_status(1.0)
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

    # ── 6. Bind-mount pseudo-filesystems into the deployment ─────────────────
    # Required for the Calamares users exec jobs (CreateUserJob, SetPasswordJob,
    # SetHostnameJob) to chroot successfully into the deployment.
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
