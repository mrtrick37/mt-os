#!/usr/bin/bash
# kyth-manual-install.sh — Manual installer for Kyth from a live ISO session.
#
# Use this when the graphical installer is unavailable (e.g. broken Wayland).
# Creates a scratch partition on the live USB, pulls the Kyth image there,
# then installs to the target disk via bootc inside podman.
#
# Usage:
#   sudo ./kyth-manual-install.sh [USB_DISK] [TARGET_DISK]
#
# Defaults:
#   USB_DISK    /dev/sda        (live USB — free space used as scratch)
#   TARGET_DISK /dev/nvme0n1    (disk to install Kyth onto — ALL DATA ERASED)

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

for dev in "$USB" "$TARGET"; do
    if [[ ! -b "$dev" ]]; then
        echo "ERROR: $dev is not a block device." >&2
        exit 1
    fi
done

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
echo "         A new partition will be added to $USB (existing partitions untouched)."
echo ""
read -r -p "Type 'yes' to continue: " CONFIRM
[[ "$CONFIRM" == "yes" ]] || { echo "Aborted."; exit 0; }

# ── Unmount any existing mounts on the target disk ────────────────────────────

echo ""
echo "==> Unmounting any existing mounts on $TARGET..."
# Unmount in reverse order (deepest first)
while IFS= read -r mp; do
    echo "    Unmounting $mp"
    umount -l "$mp" 2>/dev/null || true
done < <(findmnt -rno TARGET | grep -E "^/var/mnt/tmp" | sort -r || true)

# ── Create scratch partition on USB ───────────────────────────────────────────

echo ""
echo "==> Creating scratch partition on $USB using all free space..."

# Clean up any ghost partition entries left by previous failed attempts
echo "    Cleaning up any previous partition attempts..."
for i in 4 5 6 7 8; do
    sgdisk -d "$i" "$USB" 2>/dev/null || true
done

# Fix GPT backup header and create new partition in one operation
echo "    Fixing GPT and creating scratch partition..."
sgdisk -e -n 4:0:0 -t 4:8300 "$USB"

# Drop stale kernel partition entries, then re-add from updated GPT
partx -d --nr 4-8 "$USB" 2>/dev/null || true
partx -a "$USB" 2>/dev/null || partprobe "$USB" 2>/dev/null || true
sleep 2
udevadm settle 2>/dev/null || true

SCRATCH_PART="${USB}4"

if [[ -z "$SCRATCH_PART" || "$SCRATCH_PART" == "$USB" ]]; then
    echo "ERROR: Could not identify the new scratch partition on $USB." >&2
    exit 1
fi

echo "    Scratch partition: $SCRATCH_PART"

# ── Format and mount ──────────────────────────────────────────────────────────

echo "==> Formatting $SCRATCH_PART as ext4..."
mkfs.ext4 -F "$SCRATCH_PART"

echo "==> Mounting $SCRATCH_PART at $MOUNT..."
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
