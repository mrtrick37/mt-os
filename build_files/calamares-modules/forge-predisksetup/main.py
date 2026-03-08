#!/usr/bin/env python3
# forge-predisksetup — Calamares jobmodule
#
# Runs after the partition module's exec jobs complete.
# Reads the target disk device from globalStorage (set by partition module's
# FillGlobalStorageJob) and writes it to /tmp/forge-target-disk for the
# shellprocess@forge-install step to consume.

import re
import libcalamares


def pretty_name():
    return "Preparing installation target"


def run():
    gs = libcalamares.globalstorage

    # partition module's FillGlobalStorageJob sets this to the whole disk device
    # (e.g., /dev/sda) after the exec phase.
    disk = gs.value("bootLoaderInstallPath") or ""

    if not disk:
        # Fallback: derive disk from the partitions list.
        partitions = gs.value("partitions") or []
        for p in partitions:
            device = p.get("device", "") if isinstance(p, dict) else ""
            # Strip partition suffix: /dev/sda1→/dev/sda, /dev/nvme0n1p1→/dev/nvme0n1
            m = re.match(
                r"^(/dev/(?:sd[a-z]+|vd[a-z]+|hd[a-z]+|nvme\d+n\d+))\d+$",
                device,
            )
            if m:
                disk = m.group(1)
                break

    disk = disk.strip()

    if not disk:
        return (
            "Installation error",
            "Could not determine the target disk.\n"
            "Please go back and select a disk, then try again.",
        )

    try:
        with open("/tmp/forge-target-disk", "w") as f:
            f.write(disk)
    except OSError as e:
        return ("Installation error", f"Could not record target disk: {e}")

    libcalamares.utils.debug(f"forge-predisksetup: target disk → {disk}")
    return None
