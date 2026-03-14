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

import os
import re
import subprocess
import tempfile

import libcalamares

# Source image: bundled inside the live squashfs at boot time.
# At live boot this path is read-only inside the squashfs overlay.
# bootc reads it as an OCI directory without requiring internet access.
BUNDLED_IMGREF = "oci:/usr/share/kyth/image"

# Target image: the registry ref written into the installed OS so that
# `bootc upgrade` knows where to pull future updates from.
TARGET_IMGREF = "ghcr.io/mrtrick37/kyth:latest"

# Linux filesystem data GUID — identifies the root partition bootc creates.
LINUX_FS_GUID = "0fc63daf-8483-4772-8e79-3d69d8477de4"


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
    """Return the device path of the Linux-FS partition bootc created."""
    result = subprocess.run(
        ["lsblk", "-n", "-o", "NAME,PARTTYPE", disk],
        capture_output=True, text=True, check=True,
    )
    root_part = ""
    for line in result.stdout.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[1].lower() == LINUX_FS_GUID:
            root_part = f"/dev/{parts[0].strip()}"
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

    # ── 3. Run bootc install to-disk ─────────────────────────────────────────
    # bootc wipes the disk, creates its own GPT + EFI + root partitions, and
    # writes the OS image.  This is the only step that touches the disk.
    _log(f"running: bootc install to-disk {disk}")
    libcalamares.job.setprogress(0.03)

    try:
        result = subprocess.run(
            [
                "bootc", "install", "to-disk",
                "--source-imgref", BUNDLED_IMGREF,
                "--target-imgref", TARGET_IMGREF,
                disk,
            ],
            check=True,
            capture_output=True,
            text=True,
        )
    except subprocess.CalledProcessError as e:
        detail = (e.stderr or e.stdout or "").strip()
        _log(f"bootc stderr: {detail}")
        return (
            "Installation failed",
            f"bootc install to-disk failed (exit code {e.returncode}).\n\n"
            + (detail if detail else "Check that the selected disk is not in use and try again."),
        )

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
