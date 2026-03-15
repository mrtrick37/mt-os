#!/usr/bin/bash
# kyth-manual-install.sh — Manual installer for Kyth from a live ISO session.
#
# Use this when the graphical installer is unavailable (e.g. broken Wayland).
# Pulls the Kyth image onto free space on the live USB, then installs to the
# target NVMe/SATA disk via bootc.
#
# Usage:
#   sudo ./kyth-manual-install.sh [USB_DISK] [TARGET_DISK]
#
# Defaults:
#   USB_DISK    /dev/sda        (live USB — free space used as scratch)
#   TARGET_DISK /dev/nvme0n1    (disk to install Kyth onto)

set -euo pipefail

USB="${1:-/dev/sda}"
TARGET="${2:-/dev/nvme0n1}"
IMAGE="ghcr.io/mrtrick37/kyth:latest"
MOUNT="/mnt/kyth-scratch"

# ── Sanity checks ─────────────────────────────────────────────────────────────

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Run as root (sudo)." >&2
    exit 1
fi

if [[ ! -b "$USB" ]]; then
    echo "ERROR: $USB is not a block device." >&2
    exit 1
fi

if [[ ! -b "$TARGET" ]]; then
    echo "ERROR: $TARGET is not a block device." >&2
    exit 1
fi

if [[ "$USB" == "$TARGET" ]]; then
    echo "ERROR: USB scratch disk and install target must be different devices." >&2
    exit 1
fi

echo ""
echo "=== Kyth Manual Installer ==="
echo ""
echo "  Scratch USB : $USB"
echo "  Install to  : $TARGET"
echo "  Image       : $IMAGE"
echo ""
echo "WARNING: ALL DATA on $TARGET will be erased."
echo "         A new partition will be added to $USB (existing data untouched)."
echo ""
read -r -p "Type 'yes' to continue: " CONFIRM
[[ "$CONFIRM" == "yes" ]] || { echo "Aborted."; exit 0; }

# ── Create scratch partition on USB ───────────────────────────────────────────

echo ""
echo "==> Creating scratch partition on $USB (using free space)..."

# Append a new partition covering all remaining free space
echo ',,L' | sfdisk --append --no-reread "$USB"

# Re-read partition table
partprobe "$USB" 2>/dev/null || true
sleep 2

# Find the new partition (highest-numbered on the device)
SCRATCH_PART=$(lsblk -dpno NAME "$USB" | sort -V | tail -1)
# lsblk on the disk itself returns the disk; list partitions instead
SCRATCH_PART=$(lsblk -pno NAME "$USB" | grep -v "^${USB}$" | sort -V | tail -1)

if [[ -z "$SCRATCH_PART" || "$SCRATCH_PART" == "$USB" ]]; then
    echo "ERROR: Could not identify new scratch partition on $USB." >&2
    exit 1
fi

echo "    Scratch partition: $SCRATCH_PART"

# ── Format and mount ──────────────────────────────────────────────────────────

echo "==> Formatting $SCRATCH_PART as ext4..."
mkfs.ext4 -F "$SCRATCH_PART"

echo "==> Mounting at $MOUNT..."
mkdir -p "$MOUNT"
mount "$SCRATCH_PART" "$MOUNT"

mkdir -p "$MOUNT/tmp" "$MOUNT/containers"

# ── Pull image ────────────────────────────────────────────────────────────────

echo ""
echo "==> Pulling $IMAGE to $SCRATCH_PART..."
echo "    This will take a while depending on your connection."
echo ""

TMPDIR="$MOUNT/tmp" podman \
    --root "$MOUNT/containers" \
    --tmpdir "$MOUNT/tmp" \
    pull "$IMAGE"

# ── Install ───────────────────────────────────────────────────────────────────

echo ""
echo "==> Installing Kyth to $TARGET..."
echo ""

podman \
    --root "$MOUNT/containers" \
    run --rm --privileged \
    --pid=host \
    --security-opt label=disable \
    -v /dev:/dev \
    "$IMAGE" \
    bootc install to-disk "$TARGET"

# ── Done ──────────────────────────────────────────────────────────────────────

echo ""
echo "Installation complete!"
echo "Remove the live USB and reboot to start Kyth."
echo ""
