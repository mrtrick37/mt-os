#!/usr/bin/env python3
# kyth-predisksetup — Calamares jobmodule
#
# Runs BEFORE the partition module's exec jobs.
# Reads the target disk from globalStorage, forcefully unmounts all of its
# partitions, and clears any stale partition/filesystem signatures so that
# the partition module's sfdisk call succeeds on a disk that was previously
# used (e.g. a prior bootc install attempt).

import re
import subprocess
import libcalamares


def pretty_name():
    return "Preparing installation target"


def _log(msg):
    libcalamares.utils.debug(f"kyth-predisksetup: {msg}")


def _run_best_effort(cmd):
    """Run a command, log it, ignore failures."""
    _log(" ".join(str(c) for c in cmd))
    try:
        subprocess.run(cmd, check=True, capture_output=True)
    except (subprocess.CalledProcessError, FileNotFoundError) as e:
        _log(f"  (ignored error: {e})")


def run():
    gs = libcalamares.globalstorage

    disk = (gs.value("bootLoaderInstallPath") or "").strip()

    if not disk:
        for part in (gs.value("partitions") or []):
            device = part.get("device", "") if isinstance(part, dict) else ""
            m = re.match(
                r"^(/dev/(?:sd[a-z]+|vd[a-z]+|hd[a-z]+|nvme\d+n\d+))(?:p?\d+)?$",
                device,
            )
            if m:
                disk = m.group(1)
                break

    if not disk:
        return (
            "Installation error",
            "Could not determine the target disk.\n"
            "Please go back and select a disk, then try again.",
        )

    _log(f"target disk: {disk}")

    # ── Unmount everything on the disk ───────────────────────────────────────
    # The live ISO's udisks2 may have auto-mounted partitions from a previous
    # install.  sfdisk (run by the Calamares partition module next) will fail
    # with EBUSY if any partition on the disk is still mounted.

    # Collect all mount points for partitions on this disk.
    try:
        result = subprocess.run(
            ["lsblk", "-lnpo", "NAME,MOUNTPOINT", disk],
            capture_output=True, text=True, check=True,
        )
        for line in result.stdout.splitlines():
            parts = line.split(None, 1)
            if len(parts) == 2:
                name, mp = parts[0].strip(), parts[1].strip()
                if mp and mp != "[SWAP]" and name != disk:
                    _log(f"unmounting {mp} ({name})")
                    _run_best_effort(["umount", "-R", "-l", mp])
    except (subprocess.CalledProcessError, FileNotFoundError):
        pass

    # Deactivate any swap on the disk.
    _run_best_effort(["swapoff", "--all"])

    # Deactivate any LVM volume groups that might be using the disk.
    _run_best_effort(["vgchange", "-an"])

    # Clear filesystem/partition signatures so sfdisk sees a blank disk.
    # --force is needed when the kernel still has the old partition table.
    _run_best_effort(["wipefs", "--all", "--force", disk])

    # Tell the kernel to re-read the (now empty) partition table.
    _run_best_effort(["partprobe", disk])
    _run_best_effort(["udevadm", "settle"])

    _log("disk cleared — ready for partition module")
    return None
