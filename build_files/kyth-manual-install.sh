#!/usr/bin/bash
# kyth-manual-install.sh — Manual installer for Kyth from a live ISO session.
#
# Use this when the graphical installer is unavailable (e.g. broken Wayland).
#
# Strategy: partition the target NVMe into a temporary scratch area + final
# root/EFI partitions. Bind-mount the scratch partition over
# /var/lib/containers (podman's default storage path) so the image is pulled
# there once — no second copy, no path remapping, no overlay-config mismatch.
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

# ── Mount scratch as the default container storage path ───────────────────────
#
# Bind-mounting over /var/lib/containers means podman uses the scratch
# partition for image storage without any --root remapping. bootc running
# inside the container sees /var/lib/containers at the same standard path,
# so containers-storage lookup works without overlay-config mismatches.

echo ""
echo "==> Mounting scratch partition (${TARGET}p3)..."
mkdir -p "$SCRATCH_MOUNT"
mount "${TARGET}p3" "$SCRATCH_MOUNT"
mkdir -p "$SCRATCH_MOUNT/containers" "$SCRATCH_MOUNT/tmp"

mkdir -p /var/lib/containers
mount --bind "$SCRATCH_MOUNT/containers" /var/lib/containers

# ── Pull image ────────────────────────────────────────────────────────────────

echo ""
echo "==> Pulling $IMAGE to scratch partition..."
echo "    This will take a while depending on your connection."
echo ""
TMPDIR="$SCRATCH_MOUNT/tmp" podman \
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
podman run --rm --privileged \
    --pid=host \
    --security-opt label=disable \
    -v /dev:/dev \
    -v "${ROOT_MOUNT}:/target" \
    -v /run/containers:/run/containers \
    -v /var/lib/containers:/var/lib/containers \
    "$IMAGE" \
    bootc install to-filesystem \
        --source-imgref "containers-storage:${IMAGE}" \
        /target

# ── Done ──────────────────────────────────────────────────────────────────────

echo ""
echo "Installation complete!"
echo ""
echo "NOTE: ${TARGET}p3 is a 20GB scratch partition that can be deleted after"
echo "      first boot with: sudo sgdisk -d 3 $TARGET"
echo ""
echo "Reboot now to start Kyth."
echo ""
