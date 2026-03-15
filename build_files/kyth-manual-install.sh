#!/usr/bin/bash
# kyth-manual-install.sh — Manual installer for Kyth from a live ISO session.
#
# Use this when the graphical installer is unavailable (e.g. broken Wayland).
#
# Strategy: partition the target NVMe into a temporary scratch area + final
# root/EFI partitions. Pull the image to scratch, then use
# bootc install to-filesystem to write to the root partition — no conflict
# since scratch and root are separate partitions on the same disk.
#
# Usage:
#   sudo ./kyth-manual-install.sh [TARGET_DISK]
#
# Default TARGET_DISK: /dev/nvme0n1

set -euo pipefail

TARGET="${1:-/dev/nvme0n1}"
IMAGE="ghcr.io/mrtrick37/kyth:latest"
SCRATCH_MOUNT="/mnt/kyth-scratch"
ROOT_MOUNT="/mnt/kyth-root"

# ── Sanity checks ─────────────────────────────────────────────────────────────

[[ $EUID -eq 0 ]]   || { echo "ERROR: Run as root (sudo)."; exit 1; }
[[ -b "$TARGET" ]]  || { echo "ERROR: $TARGET is not a block device."; exit 1; }

echo ""
echo "=== Kyth Manual Installer ==="
echo ""
echo "  Install to : $TARGET"
echo "  Image      : $IMAGE"
echo ""
echo "  Partition layout that will be created on $TARGET:"
echo "    p1  1MB    BIOS boot"
echo "    p2  512MB  EFI"
echo "    p3  20GB   Scratch (temporary — for pulling the image)"
echo "    p4  rest   Root (Kyth OS)"
echo ""
echo "WARNING: ALL DATA on $TARGET will be erased."
echo ""
read -r -p "Type 'yes' to continue: " CONFIRM
[[ "$CONFIRM" == "yes" ]] || { echo "Aborted."; exit 0; }

# ── Unmount anything on the target disk ───────────────────────────────────────

echo ""
echo "==> Unmounting any existing mounts on $TARGET..."
# Find ALL mountpoints whose source is a partition on $TARGET, unmount deepest first
while IFS= read -r mp; do
    echo "    $mp"
    umount -l "$mp" 2>/dev/null || true
done < <(findmnt -rno SOURCE,TARGET | awk -v tgt="$TARGET" '$1 ~ "^" tgt {print $2}' | sort -r || true)

# ── Partition the target disk ─────────────────────────────────────────────────

echo ""
echo "==> Partitioning $TARGET..."
sgdisk --zap-all "$TARGET"
sgdisk \
    -n 1:0:+1M    -t 1:ef02 \
    -n 2:0:+512M  -t 2:ef00 \
    -n 3:0:+20G   -t 3:8300 \
    -n 4:0:0      -t 4:8300 \
    "$TARGET"

partx -u "$TARGET" 2>/dev/null || partprobe "$TARGET" 2>/dev/null || true
sleep 3
udevadm settle 2>/dev/null || true

# ── Format partitions ─────────────────────────────────────────────────────────

echo "==> Formatting partitions..."
mkfs.fat -F32 "${TARGET}p2"
mkfs.ext4 -F  "${TARGET}p3"
mkfs.ext4 -F  "${TARGET}p4"

# ── Mount scratch and pull image ──────────────────────────────────────────────

echo ""
echo "==> Mounting scratch partition (${TARGET}p3)..."
mkdir -p "$SCRATCH_MOUNT"
mount "${TARGET}p3" "$SCRATCH_MOUNT"
mkdir -p "$SCRATCH_MOUNT/tmp" "$SCRATCH_MOUNT/containers"

echo ""
echo "==> Pulling $IMAGE to scratch partition..."
echo "    This will take a while depending on your connection."
echo ""
TMPDIR="$SCRATCH_MOUNT/tmp" podman \
    --root "$SCRATCH_MOUNT/containers" \
    --tmpdir "$SCRATCH_MOUNT/tmp" \
    pull "$IMAGE"

# ── Mount target root and install ─────────────────────────────────────────────

echo ""
echo "==> Mounting target root (${TARGET}p4) and EFI (${TARGET}p2)..."
mkdir -p "$ROOT_MOUNT"
mount "${TARGET}p4" "$ROOT_MOUNT"
mkdir -p "$ROOT_MOUNT/boot/efi"
mount "${TARGET}p2" "$ROOT_MOUNT/boot/efi"

echo ""
echo "==> Installing Kyth to $TARGET..."
echo ""
podman \
    --root "$SCRATCH_MOUNT/containers" \
    run --rm --privileged \
    --pid=host \
    --security-opt label=disable \
    -v /dev:/dev \
    -v "${ROOT_MOUNT}:/target" \
    -v "$SCRATCH_MOUNT/containers:/var/lib/containers:ro" \
    "$IMAGE" \
    bootc install to-filesystem /target

# ── Done ──────────────────────────────────────────────────────────────────────

echo ""
echo "Installation complete!"
echo ""
echo "NOTE: ${TARGET}p3 is a 20GB scratch partition that can be deleted after"
echo "      first boot with: sudo sgdisk -d 3 $TARGET"
echo ""
echo "Reboot now to start Kyth."
echo ""
