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
#     pulled by podman) via a containers-storage volume mount and a minimal
#     storage.conf override.  If that lookup succeeds bootc skips re-downloading;
#     if not, it falls back to docker:// — both paths write to the large
#     partitions so either works.
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
echo "    p4  rest   Root (Kyth OS — bootc installs here)"
echo ""
echo "WARNING: ALL DATA on $TARGET will be erased."
echo ""
read -r -p "Type 'yes' to continue: " CONFIRM
[[ "$CONFIRM" == "yes" ]] || { echo "Aborted."; exit 0; }

# ── Unmount anything on the target disk ───────────────────────────────────────

echo ""
echo "==> Unmounting any existing mounts on $TARGET..."
# Also clean up /sysroot if a previous run left a bind mount there.
umount -R /sysroot 2>/dev/null || umount -l /sysroot 2>/dev/null || true
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

# Temp directory for bootc's blob decompression — placed at the sysroot root
# level so it is NOT inside /var (which bootc manages as the var stateroot).
# Peak usage ~20 GB; the 456 GiB root partition has plenty of room.
BOOTC_TMP="$ROOT_MOUNT/.kyth-install-tmp"
mkdir -p "$BOOTC_TMP"

# ── Bind target onto /sysroot on the HOST before starting the container ───────
#
# With --privileged, podman copies the host's full mount namespace into the
# container, including the live ISO's shared /sysroot mount.  A -v bind mount
# applied inside that namespace loses the race against host shared propagation.
# bootc ALWAYS writes the ostree repo to /sysroot/ostree/repo/ internally.
#
# The reliable fix: rbind our target at /sysroot on the HOST first.  The
# container inherits this naturally — no volume-mount override needed.
mkdir -p /sysroot
mount --rbind "$ROOT_MOUNT" /sysroot
# Ensure /sysroot is cleaned up even if the install fails.
trap 'umount -R /sysroot 2>/dev/null || umount -l /sysroot 2>/dev/null || true' EXIT

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

# /sysroot is already our target (host rbind above); the container inherits it.
# /var/lib/containers lets bootc find the already-pulled image in host storage.
# /var/tmp is redirected to the large root partition so blob decompression never
# fills the scratch partition or the live ISO's tmpfs.
TMPDIR="$SCRATCH_MOUNT/tmp" \
podman \
    --tmpdir "$SCRATCH_MOUNT/tmp" \
    run --rm --privileged \
    --pid=host \
    --security-opt label=disable \
    -v /dev:/dev \
    -v /run/containers:/run/containers \
    -v /var/lib/containers:/var/lib/containers \
    -v "${STORAGE_CONF}:/etc/containers/storage.conf:ro" \
    -v "${BOOTC_TMP}:/var/tmp" \
    "$IMAGE" \
    bootc install to-filesystem \
        --source-imgref "containers-storage:${IMAGE}" \
        /sysroot

# Remove the temp dir left at the sysroot root (not part of the deployment).
rm -rf "$BOOTC_TMP" 2>/dev/null || true

# ── Done ──────────────────────────────────────────────────────────────────────

echo ""
echo "Installation complete!"
echo ""
echo "NOTE: ${TARGET}p3 is a 20GB scratch partition that can be deleted after"
echo "      first boot with: sudo sgdisk -d 3 $TARGET"
echo ""
echo "Reboot now to start Kyth."
echo ""
