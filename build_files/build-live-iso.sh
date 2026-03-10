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
    "${ISO_DIR}/boot/grub2/themes/forge" \
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
        --exclude='./run/*' \
        2> >(grep -v 'xattr' >&2)
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
    -no-xattrs \
    -e proc -e sys -e dev -e run

# ── 5a. GRUB config + dark theme (shared by EFI and BIOS GRUB2) ─────────────
echo "==> Writing GRUB config and theme"
LIVE_ARGS="root=live:CDLABEL=${VOLID} rd.live.image rd.live.overlay=tmpfs selinux=0 quiet splash"
PERSISTENT_ARGS="root=live:CDLABEL=${VOLID} rd.live.image rd.live.overlay=LABEL=forge-overlay rd.live.overlayfs=1 selinux=0 quiet splash"
INSTALL_ARGS="root=live:CDLABEL=${VOLID} rd.live.image rd.live.overlay=tmpfs selinux=0 quiet splash"

# Write the theme file
cat > "${ISO_DIR}/boot/grub2/themes/forge/theme.txt" << 'THEMEEOF'
# Forge GRUB2 dark theme

title-text: ""
desktop-color: "#0d1117"
terminal-font: "DejaVu Sans Regular 14"
terminal-left: "0%"
terminal-top: "0%"
terminal-width: "100%"
terminal-height: "100%"
terminal-border: "0"

+ boot_menu {
    left   = 30%
    top    = 35%
    width  = 40%
    height = 40%
    item_font               = "DejaVu Sans Regular 14"
    item_color              = "#abb2bf"
    selected_item_color     = "#ffffff"
    item_height             = 36
    item_padding            = 14
    item_spacing            = 4
    scrollbar               = false
}

+ label {
    top    = 25%
    left   = 0%
    width  = 100%
    height = 50
    text   = "FORGE 43"
    font   = "DejaVu Sans Bold 28"
    color  = "#61afef"
    align  = "center"
}
THEMEEOF

# Bundle the DejaVu fonts GRUB2 needs for the theme.
# grub2-mkfont is in grub2-tools; fall back gracefully if not present.
for src_font in \
    "${ROOTFS}/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf" \
    "${ROOTFS}/usr/share/fonts/dejavu/DejaVuSans.ttf"; do
    if [[ -f "${src_font}" ]]; then
        grub2-mkfont -s 14 -o "${ISO_DIR}/boot/grub2/themes/forge/dejavusans14.pf2" "${src_font}" 2>/dev/null || true
        grub2-mkfont -s 28 -o "${ISO_DIR}/boot/grub2/themes/forge/dejavusansbold28.pf2" "${src_font}" 2>/dev/null || true
        break
    fi
done

# Copy unicode.pf2 (GRUB2 default font) for the terminal fallback
for unicode_src in \
    "${ROOTFS}/usr/share/grub/unicode.pf2" \
    "${ROOTFS}/boot/grub2/fonts/unicode.pf2" \
    "/usr/share/grub/unicode.pf2"; do
    if [[ -f "${unicode_src}" ]]; then
        cp "${unicode_src}" "${ISO_DIR}/boot/grub2/unicode.pf2"
        break
    fi
done

# Single grub.cfg used by both EFI (/EFI/BOOT/grub.cfg) and
# BIOS GRUB2 (/boot/grub2/grub.cfg) — symlinked below.
cat > "${ISO_DIR}/boot/grub2/grub.cfg" << GRUBEOF
set default=0
set timeout=10

# ── Graphical terminal + dark theme ───────────────────────────────────────────
insmod all_video
insmod gfxterm
insmod gfxmenu
insmod png

if loadfont /boot/grub2/unicode.pf2; then
    set gfxmode=auto
    terminal_output gfxterm
    # Bundled DejaVu fonts for the theme labels
    loadfont /boot/grub2/themes/forge/dejavusans14.pf2 || true
    loadfont /boot/grub2/themes/forge/dejavusansbold28.pf2 || true
    set theme=/boot/grub2/themes/forge/theme.txt
else
    # Text-mode fallback: dark colors
    set color_normal=light-gray/black
    set color_highlight=black/light-cyan
    set menu_color_normal=light-gray/black
    set menu_color_highlight=black/light-cyan
fi

# ── Boot entries ───────────────────────────────────────────────────────────────
menuentry "Try Forge Live" --class fedora --class gnu-linux --class os {
    linux /images/pxeboot/vmlinuz ${LIVE_ARGS}
    initrd /images/pxeboot/initrd.img
}

menuentry "Try Forge Live (Persistent)" --class fedora --class gnu-linux --class os {
    linux /images/pxeboot/vmlinuz ${PERSISTENT_ARGS}
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

# EFI GRUB reads from /EFI/BOOT/grub.cfg — copy the shared config there
cp "${ISO_DIR}/boot/grub2/grub.cfg" "${ISO_DIR}/EFI/BOOT/grub.cfg"

# ── 5b. UEFI EFI boot image (FAT) ────────────────────────────────────────────
echo "==> Creating UEFI EFI boot image"

# Use grubx64.efi directly as BOOTX64.EFI.
# Shim is intentionally skipped: this image is unsigned and shim would
# fail to chain-load an unverified grub binary.  grubx64.efi works on
# both real UEFI hardware and QEMU+OVMF without secure-boot concerns.
GRUB_EFI=""
for candidate in \
    "${ROOTFS}/boot/efi/EFI/fedora/grubx64.efi" \
    "${ROOTFS}/boot/efi/EFI/BOOT/BOOTX64.EFI" \
    "${ROOTFS}/usr/lib/grub/x86_64-efi/grub.efi"; do
    if sudo test -f "${candidate}"; then
        GRUB_EFI="${candidate}"
        break
    fi
done

if [[ -z "${GRUB_EFI}" ]]; then
    echo "WARNING: grubx64.efi not found in rootfs — UEFI boot will not work" >&2
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

# ── 5b-ii. startup.nsh — UEFI shell fallback ────────────────────────────────
# Some UEFI implementations ignore the El Torito EFI entry and fall through
# to the UEFI shell. The shell auto-executes startup.nsh from the first
# readable filesystem (FS0 = the ISO). This launches GRUB directly.
cat > "${ISO_DIR}/startup.nsh" << 'NSHEOF'
@echo -off
echo Booting Forge...
fs0:\EFI\BOOT\BOOTX64.EFI
NSHEOF

# ── 5c. BIOS boot — GRUB2 preferred, syslinux fallback ───────────────────────
# GRUB2 BIOS: uses grub2-mkimage (from grub2-tools-minimal on the host) and
# the i386-pc modules from grub2-pc installed in the container rootfs.
# This replaces the syslinux menu with a modern graphical GRUB2 interface.
echo "==> Setting up BIOS boot"
HAVE_ISOLINUX=false
HAVE_BIOS_GRUB=false

GRUB_I386_MODS="${ROOTFS}/usr/lib/grub/i386-pc"
if [[ -d "${GRUB_I386_MODS}" ]] && command -v grub2-mkimage &>/dev/null; then
    echo "    Using GRUB2 BIOS (grub2-mkimage)"
    BIOS_IMG="${ISO_DIR}/boot/grub2/bios.img"
    grub2-mkimage \
        -O i386-pc-eltorito \
        -o "${BIOS_IMG}" \
        -p /boot/grub2 \
        -d "${GRUB_I386_MODS}" \
        linux normal iso9660 biosdisk all_video gfxterm gfxmenu png echo test ls
    HAVE_BIOS_GRUB=true
    echo "    GRUB2 BIOS boot image: OK"
else
    if [[ ! -d "${GRUB_I386_MODS}" ]]; then
        echo "    NOTE: grub2-pc not in rootfs — falling back to syslinux for BIOS" >&2
    fi
    if ! command -v grub2-mkimage &>/dev/null; then
        echo "    NOTE: grub2-mkimage not found on host — install grub2-tools for GRUB2 BIOS" >&2
        echo "          sudo dnf install grub2-tools-minimal" >&2
    fi
fi

# Syslinux fallback — used only if GRUB2 BIOS image could not be created.
# Also kept in the ISO for hybrid MBR legacy compatibility.
ISOLINUX_BIN="${ROOTFS}/usr/share/syslinux/isolinux.bin"
if ! "${HAVE_BIOS_GRUB}" && sudo test -f "${ISOLINUX_BIN}"; then
    echo "    Falling back to syslinux"
    sudo cp "${ISOLINUX_BIN}" "${ISO_DIR}/isolinux/"
    for f in ldlinux.c32 vesamenu.c32 libcom32.c32 libutil.c32; do
        src="${ROOTFS}/usr/share/syslinux/${f}"
        sudo test -f "${src}" && sudo cp "${src}" "${ISO_DIR}/isolinux/" || true
    done

    # Dark color scheme for vesamenu fallback
    cat > "${ISO_DIR}/isolinux/isolinux.cfg" << ISOLINUXEOF
default vesamenu.c32
timeout 100
menu title Forge 43 Live

menu color screen     37;40    #a0000000 #00000000 std
menu color border     30;44    #00000000 #00000000 std
menu color title      1;37;44  #ffffffff #00000000 std
menu color scrollbar  30;44    #40000000 #00000000 std
menu color sel        7;37;40  #e0ffffff #20207fff std
menu color hotsel     1;7;37;40 #e0ffffff #20207fff std
menu color unsel      37;44    #70ffffff #00000000 std
menu color help       37;40    #c0ffffff #00000000 std
menu color timeout_msg 37;40   #80ffffff #00000000 std
menu color timeout    1;37;40  #c0ffffff #00000000 std
menu color cmdline    37;40    #c0ffffff #00000000 std
menu hshift 13
menu margin 8
menu rows 5
menu vshift 12
menu tabmsgrow 18
menu helpmsgrow 20

label live
  menu label Try Forge Live
  kernel /images/pxeboot/vmlinuz
  append initrd=/images/pxeboot/initrd.img ${LIVE_ARGS}

label persistent
  menu label Try Forge Live (Persistent)
  kernel /images/pxeboot/vmlinuz
  append initrd=/images/pxeboot/initrd.img ${PERSISTENT_ARGS}

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
    echo "    syslinux: OK (fallback)"
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
    -iso-level 3
    -R -J -joliet-long
)

# BIOS El Torito entry (must come before EFI entry)
if [[ "${HAVE_BIOS_GRUB}" == "true" ]]; then
    XORRISO_ARGS+=(
        -b boot/grub2/bios.img
        -no-emul-boot -boot-load-size 4 -boot-info-table
        --grub2-boot-info
    )
elif [[ "${HAVE_ISOLINUX}" == "true" ]]; then
    XORRISO_ARGS+=(
        -b isolinux/isolinux.bin
        -c isolinux/boot.cat
        -no-emul-boot -boot-load-size 4 -boot-info-table
    )
fi

# EFI El Torito entry — -eltorito-alt-boot separates it from the BIOS entry
# -e specifies the EFI boot image path (relative to ISO root) in mkisofs mode
XORRISO_ARGS+=(
    -eltorito-alt-boot
    -e images/efiboot.img
    -no-emul-boot
    --efi-boot-part --efi-boot-image
)

XORRISO_ARGS+=("${ISO_DIR}")

sudo xorriso "${XORRISO_ARGS[@]}"
sudo chown "$(id -u):$(id -g)" "${OUTPUT_DIR}/${ISO_NAME}"

ISO_SIZE=$(du -sh "${OUTPUT_DIR}/${ISO_NAME}" | cut -f1)
ISO_PATH=$(readlink -f "${OUTPUT_DIR}/${ISO_NAME}")
echo ""
echo "==> Live ISO ready"
echo "    ${ISO_PATH} (${ISO_SIZE})"
