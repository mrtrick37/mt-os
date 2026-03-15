#!/usr/bin/bash
# kyth-manual-install.sh — Manual installer for Kyth from a live ISO session.
#
# Use this when the graphical installer is unavailable (e.g. broken Wayland).
#
# Strategy:
#   • Scratch partition (p3, 20 GB) is only used for host-podman temp files
#     during the initial image pull to start the bootc container.
#   • The root partition (p4, rest of disk) provides /var/tmp for bootc's
#     ostree conversion.  The containers/image library writes both compressed
#     and decompressed blobs there simultaneously (~compressed + ~decompressed
#     = up to ~20 GB peak), so it must be on a large partition.
#   • bootc reads the image from the host's /var/lib/containers (already
#     pulled by podman run) via a containers-storage volume mount and a
#     minimal storage.conf override (no imagestore), so it never re-downloads.
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
echo "    p3  20GB   Scratch (host podman temp during image pull)"
echo "    p4  rest   Root (Kyth OS — mounted as /sysroot, provides /var/tmp for bootc)"
echo ""
echo "WARNING: ALL DATA on $TARGET will be erased."
echo ""
read -r -p "Type 'yes' to continue: " CONFIRM
[[ "$CONFIRM" == "yes" ]] || { echo "Aborted."; exit 0; }

# ── Unmount anything on the target disk ───────────────────────────────────────

echo ""
echo "==> Unmounting any existing mounts on $TARGET..."
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

# ── Mount scratch (host podman temp) ──────────────────────────────────────────

echo ""
echo "==> Mounting scratch partition (${TARGET}p3)..."
mkdir -p "$SCRATCH_MOUNT"
mount "${TARGET}p3" "$SCRATCH_MOUNT"
mkdir -p "$SCRATCH_MOUNT/tmp"

# ── Mount target root ─────────────────────────────────────────────────────────

echo ""
echo "==> Mounting target root (${TARGET}p4) and EFI (${TARGET}p2)..."
mkdir -p "$ROOT_MOUNT"
mount "${TARGET}p4" "$ROOT_MOUNT"
mkdir -p "$ROOT_MOUNT/boot/efi"
mount "${TARGET}p2" "$ROOT_MOUNT/boot/efi"

# /var/tmp for bootc's blob conversion lives on the root partition.
# Peak usage = compressed layers + decompressed layers simultaneously
# (~5 GB + ~15 GB = ~20 GB), which easily fits on the rest-of-disk partition.
mkdir -p "$ROOT_MOUNT/var/tmp-bootc"

# ── Minimal storage.conf to override the bootc image's imagestore config ──────
#
# The bootc container image ships /etc/containers/storage.conf with
# "imagestore=/usr/lib/containers/storage" which breaks containers-storage
# name lookup for externally-pulled images.  We override it with the same
# simple config the host podman uses so that containers-storage inside the
# container can find the image the host already pulled.

STORAGE_CONF="$SCRATCH_MOUNT/storage.conf"
cat > "$STORAGE_CONF" << 'EOF'
[storage]
driver = "overlay"
graphRoot = "/var/lib/containers/storage"
runRoot = "/run/containers/storage"

[storage.options.overlay]
mountopt = "nodev"
EOF

# ── Install ───────────────────────────────────────────────────────────────────

echo ""
echo "==> Installing Kyth to $TARGET..."
echo "    podman will pull the image, then bootc installs directly from"
echo "    the host's container storage — no second download."
echo ""

# TMPDIR for host podman (scratch) keeps RAM free during the pull.
# /var/lib/containers is passed into the container so bootc can read the
# already-pulled image via containers-storage without re-downloading.
# /var/tmp inside the container is the root partition (effectively unlimited).
TMPDIR="$SCRATCH_MOUNT/tmp" \
podman \
    --tmpdir "$SCRATCH_MOUNT/tmp" \
    run --rm --privileged \
    --pid=host \
    --security-opt label=disable \
    -v /dev:/dev \
    -v "${ROOT_MOUNT}:/sysroot" \
    -v /run/containers:/run/containers \
    -v /var/lib/containers:/var/lib/containers \
    -v "${STORAGE_CONF}:/etc/containers/storage.conf:ro" \
    -v "${ROOT_MOUNT}/var/tmp-bootc:/var/tmp" \
    "$IMAGE" \
    bootc install to-filesystem \
        --source-imgref "containers-storage:${IMAGE}" \
        /sysroot

# ── Done ──────────────────────────────────────────────────────────────────────

echo ""
echo "Installation complete!"
echo ""
echo "NOTE: ${TARGET}p3 is a 20GB scratch partition that can be deleted after"
echo "      first boot with: sudo sgdisk -d 3 $TARGET"
echo ""
echo "Reboot now to start Kyth."
echo ""
