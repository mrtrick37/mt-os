#!/usr/bin/env bash
# build-live-iso.sh — Build a full live desktop ISO for Forge.
#
# Flow:
#   1. Build Containerfile.live (extends forge with live support)
#   2. Export the container filesystem to a temporary rootfs
#   3. Copy kernel + live initramfs out of the rootfs
#   4. mksquashfs the rootfs → LiveOS/squashfs.img
#   5. Assemble bootable ISO: UEFI (GRUB2) + BIOS (syslinux) via xorriso
#
# Host requirements:
#   xorriso, squashfs-tools (mksquashfs), mtools, dosfstools
#   (all available via: sudo dnf install xorriso squashfs-tools mtools dosfstools)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTPUT_DIR="${REPO_ROOT}/output/live-iso"
ISO_NAME="forge-live.iso"
VOLID="Forge-43-Live"

TMPDIR_BASE="${TMPDIR:-/var/tmp}"
WORK=$(mktemp -d -p "${TMPDIR_BASE}" forge-live.XXXXXXXXXX)
ROOTFS="${WORK}/rootfs"
ISO_DIR="${WORK}/iso"

cleanup() {
    echo "==> Cleaning up ${WORK}"
    sudo rm -rf "${WORK}" 2>/dev/null || true
    podman rmi localhost/forge-live:build 2>/dev/null || true
}
trap cleanup EXIT

# Check host dependencies
for cmd in xorriso mksquashfs mkfs.fat mcopy mmd; do
    if ! command -v "${cmd}" &>/dev/null; then
        echo "ERROR: '${cmd}' not found." >&2
        echo "       Install with: sudo dnf install xorriso squashfs-tools mtools dosfstools" >&2
        exit 1
    fi
done

mkdir -p \
    "${ROOTFS}" \
    "${ISO_DIR}/LiveOS" \
    "${ISO_DIR}/images/pxeboot" \
    "${ISO_DIR}/EFI/BOOT" \
    "${ISO_DIR}/isolinux"

# ── 1. Build live variant container ─────────────────────────────────────────
echo "==> Building live container variant (this takes a while)"
podman build \
    -f "${SCRIPT_DIR}/Containerfile.live" \
    -t localhost/forge-live:build \
    "${REPO_ROOT}"

# ── 2. Export container filesystem ──────────────────────────────────────────
echo "==> Exporting container filesystem to ${ROOTFS}"
CONTAINER=$(podman create localhost/forge-live:build /bin/true)
podman export "${CONTAINER}" \
    | sudo tar -xC "${ROOTFS}" \
        --exclude='./proc/*' \
        --exclude='./sys/*' \
        --exclude='./dev/*' \
        --exclude='./run/*'
podman rm "${CONTAINER}"

# ── 3. Kernel + live initramfs ───────────────────────────────────────────────
echo "==> Locating kernel and live initramfs"
KVER=$(ls "${ROOTFS}/usr/lib/modules/" | grep cachyos | head -1)
echo "    Kernel: ${KVER}"

VMLINUZ="${ROOTFS}/usr/lib/modules/${KVER}/vmlinuz"
INITRD="${ROOTFS}/usr/lib/modules/${KVER}/initramfs-live"

[[ -f "${VMLINUZ}" ]] || { echo "ERROR: vmlinuz not found at ${VMLINUZ}" >&2; exit 1; }
[[ -f "${INITRD}"  ]] || { echo "ERROR: live initramfs not found at ${INITRD}" >&2; exit 1; }

sudo cp "${VMLINUZ}" "${ISO_DIR}/images/pxeboot/vmlinuz"
sudo cp "${INITRD}"  "${ISO_DIR}/images/pxeboot/initrd.img"
sudo chmod 644 "${ISO_DIR}/images/pxeboot/"*

# ── 4. Squashfs ──────────────────────────────────────────────────────────────
echo "==> Creating squashfs (this takes a while — the full OS is ~several GB)"
sudo mksquashfs "${ROOTFS}" "${ISO_DIR}/LiveOS/squashfs.img" \
    -comp xz \
    -noappend \
    -no-progress \
    -e proc -e sys -e dev -e run

# ── 5a. GRUB config (shared between EFI and BIOS-GRUB) ──────────────────────
echo "==> Writing GRUB config"
LIVE_ARGS="root=live:CDLABEL=${VOLID} rd.live.image rd.live.overlay=tmpfs quiet splash"
INSTALL_ARGS="root=live:CDLABEL=${VOLID} rd.live.image rd.live.overlay=tmpfs quiet"

cat > "${ISO_DIR}/EFI/BOOT/grub.cfg" << GRUBEOF
set default=0
set timeout=10

menuentry "Try Forge Live" --class fedora --class gnu-linux --class os {
    linux /images/pxeboot/vmlinuz ${LIVE_ARGS}
    initrd /images/pxeboot/initrd.img
}

menuentry "Install Forge" --class fedora --class gnu-linux --class os {
    linux /images/pxeboot/vmlinuz ${INSTALL_ARGS}
    initrd /images/pxeboot/initrd.img
}

menuentry "Check media and boot Forge Live" --class fedora --class gnu-linux --class os {
    linux /images/pxeboot/vmlinuz ${LIVE_ARGS} rd.live.check
    initrd /images/pxeboot/initrd.img
}
GRUBEOF

# ── 5b. UEFI EFI boot image (FAT) ────────────────────────────────────────────
echo "==> Creating UEFI EFI boot image"

# Find GRUB/shim EFI binary in the rootfs
GRUB_EFI=""
for candidate in \
    "${ROOTFS}/boot/efi/EFI/fedora/shimx64.efi" \
    "${ROOTFS}/boot/efi/EFI/BOOT/BOOTX64.EFI" \
    "${ROOTFS}/boot/efi/EFI/fedora/grubx64.efi"; do
    if sudo test -f "${candidate}"; then
        GRUB_EFI="${candidate}"
        break
    fi
done

if [[ -z "${GRUB_EFI}" ]]; then
    echo "WARNING: No UEFI EFI binary found in rootfs — EFI boot will not work" >&2
else
    sudo cp "${GRUB_EFI}" "${ISO_DIR}/EFI/BOOT/BOOTX64.EFI"
    echo "    EFI binary: ${GRUB_EFI##*/}"
fi

# Create a small FAT image containing the EFI files (El Torito EFI boot)
EFI_IMG="${ISO_DIR}/images/efiboot.img"
truncate -s 15M "${EFI_IMG}"
mkfs.fat -n "EFIBOOT" "${EFI_IMG}"
mmd  -i "${EFI_IMG}" ::/EFI ::/EFI/BOOT
[[ -f "${ISO_DIR}/EFI/BOOT/BOOTX64.EFI" ]] \
    && mcopy -i "${EFI_IMG}" "${ISO_DIR}/EFI/BOOT/BOOTX64.EFI" ::/EFI/BOOT/BOOTX64.EFI
mcopy -i "${EFI_IMG}" "${ISO_DIR}/EFI/BOOT/grub.cfg" ::/EFI/BOOT/grub.cfg

# ── 5c. BIOS boot (syslinux) ─────────────────────────────────────────────────
echo "==> Setting up BIOS boot (syslinux)"
HAVE_ISOLINUX=false
ISOLINUX_BIN="${ROOTFS}/usr/share/syslinux/isolinux.bin"

if sudo test -f "${ISOLINUX_BIN}"; then
    sudo cp "${ISOLINUX_BIN}" "${ISO_DIR}/isolinux/"
    for f in ldlinux.c32 vesamenu.c32 libcom32.c32 libutil.c32; do
        src="${ROOTFS}/usr/share/syslinux/${f}"
        sudo test -f "${src}" && sudo cp "${src}" "${ISO_DIR}/isolinux/" || true
    done

    cat > "${ISO_DIR}/isolinux/isolinux.cfg" << ISOLINUXEOF
default vesamenu.c32
timeout 100
menu title Forge 43 Live

label live
  menu label Try Forge Live
  kernel /images/pxeboot/vmlinuz
  append initrd=/images/pxeboot/initrd.img ${LIVE_ARGS}

label install
  menu label Install Forge
  kernel /images/pxeboot/vmlinuz
  append initrd=/images/pxeboot/initrd.img ${INSTALL_ARGS}

label check
  menu label Check media and boot Forge Live
  kernel /images/pxeboot/vmlinuz
  append initrd=/images/pxeboot/initrd.img ${LIVE_ARGS} rd.live.check
ISOLINUXEOF
    HAVE_ISOLINUX=true
    echo "    syslinux: OK"
else
    echo "WARNING: syslinux not found in rootfs — BIOS boot unavailable" >&2
fi

# ── 6. Assemble ISO ───────────────────────────────────────────────────────────
echo "==> Assembling ISO: ${OUTPUT_DIR}/${ISO_NAME}"
# output/ may be owned by root from a previous BIB/sudo build — use sudo mkdir
sudo mkdir -p "${OUTPUT_DIR}"
sudo chown "$(id -u):$(id -g)" "${OUTPUT_DIR}"

XORRISO_ARGS=(
    -as mkisofs
    -o "${OUTPUT_DIR}/${ISO_NAME}"
    -V "${VOLID}"
    -R -J -joliet-long
    --efi-boot images/efiboot.img
    -efi-boot-part --efi-boot-image
)

if [[ "${HAVE_ISOLINUX}" == "true" ]]; then
    XORRISO_ARGS+=(
        -b isolinux/isolinux.bin
        -c isolinux/boot.cat
        -no-emul-boot -boot-load-size 4 -boot-info-table
    )
fi

XORRISO_ARGS+=("${ISO_DIR}")

sudo xorriso "${XORRISO_ARGS[@]}"
sudo chown "$(id -u):$(id -g)" "${OUTPUT_DIR}/${ISO_NAME}"

ISO_SIZE=$(du -sh "${OUTPUT_DIR}/${ISO_NAME}" | cut -f1)
ISO_PATH=$(readlink -f "${OUTPUT_DIR}/${ISO_NAME}")
echo ""
echo "==> Live ISO ready"
echo "    ${ISO_PATH} (${ISO_SIZE})"
