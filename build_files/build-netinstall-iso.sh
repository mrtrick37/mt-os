#!/usr/bin/env bash

# build-netinstall-iso.sh — Build a minimal network-install ISO for Kyth.
#
# Identical to build-live-iso.sh except step 3b is replaced:
# instead of bundling the OCI image (~3-4 GB) into the squashfs, a small
# text file (/usr/share/kyth/source-imgref) is written with the registry
# URL. kyth-bootcinstall detects the absence of the OCI bundle and pulls
# from the registry at install time.
#
# Result: an ISO with a full live desktop for diagnostics/networking,
# but no embedded OS image — roughly 3-4 GB smaller than the offline ISO.
#
# Requirements: same as build-live-iso.sh
#   xorriso squashfs-tools mtools dosfstools skopeo (skopeo not used here but checked)
#   sudo dnf install xorriso squashfs-tools mtools dosfstools

set -euo pipefail

SOURCE_TAG="${SOURCE_TAG:-latest}"
LOCAL_BASE="localhost/kyth:${SOURCE_TAG}"
# Reuse the same live container cache as build-live-iso.sh
if [[ "${SOURCE_TAG}" == "latest" ]]; then
    LIVE_BUILD_TAG="kyth-live:build"
else
    LIVE_BUILD_TAG="kyth-live:build-${SOURCE_TAG}"
fi

# The registry ref the installer will pull from at install time.
SOURCE_IMGREF="${SOURCE_IMGREF:-docker://ghcr.io/mrtrick37/kyth:${SOURCE_TAG}}"

# ── Sudo setup ────────────────────────────────────────────────────────────────
if command sudo -n true 2>/dev/null; then
    _ASKPASS=""
else
    IFS= read -rsp "Enter sudo password (needed for export, squashfs, and ISO assembly): " _build_pw
    echo
    printf '%s\n' "$_build_pw" | command sudo -S true 2>/dev/null \
        || { echo "error: incorrect sudo password"; exit 1; }
    export _KYTH_BUILD_PW="$_build_pw"
    unset _build_pw
    _ASKPASS=$(mktemp --tmpdir kyth-build-askpass.XXXXXXXX)
    chmod 0700 "$_ASKPASS"
    printf '#!/bin/sh\nprintf "%%s\\n" "$_KYTH_BUILD_PW"\n' > "$_ASKPASS"
    export SUDO_ASKPASS="$_ASKPASS"
    sudo() { command sudo -A "$@"; }
fi

# ── Base image ────────────────────────────────────────────────────────────────
if ! docker image inspect "${LOCAL_BASE}" >/dev/null 2>&1; then
    if [[ "${SOURCE_TAG}" == "latest" ]]; then
        if docker image inspect ghcr.io/mrtrick37/kyth:latest >/dev/null 2>&1; then
            echo "Retagging ghcr.io/mrtrick37/kyth:latest as ${LOCAL_BASE}..."
            docker tag ghcr.io/mrtrick37/kyth:latest "${LOCAL_BASE}"
        else
            echo "Base image ${LOCAL_BASE} not found. Building..."
            just build || { echo "Failed to build base image."; exit 1; }
        fi
    else
        echo "==> Pulling ghcr.io/mrtrick37/kyth:${SOURCE_TAG} from registry..."
        if docker pull "ghcr.io/mrtrick37/kyth:${SOURCE_TAG}"; then
            docker tag "ghcr.io/mrtrick37/kyth:${SOURCE_TAG}" "${LOCAL_BASE}"
        else
            echo "ERROR: ${LOCAL_BASE} not found locally and could not pull from registry." >&2
            echo "       Make sure the ${SOURCE_TAG} image has been pushed to ghcr.io." >&2
            exit 1
        fi
    fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTPUT_DIR="${REPO_ROOT}/output/netinstall-iso"
ISO_NAME="kyth-netinstall-${SOURCE_TAG}.iso"
VOLID="Kyth-43-NetInst"

TMPDIR_BASE="${TMPDIR:-/var/tmp}"
WORK=$(mktemp -d -p "${TMPDIR_BASE}" kyth-netinstall.XXXXXXXXXX)
ROOTFS="${WORK}/rootfs"
ISO_DIR="${WORK}/iso"

if ! command -v docker &>/dev/null || ! docker info &>/dev/null; then
    echo "ERROR: Docker is not installed or not running." >&2
    exit 1
fi
echo "==> Using container engine: docker"

cleanup() {
    echo "==> Cleaning up ${WORK}"
    sudo rm -rf "${WORK}" 2>/dev/null || true
    [[ -n "${_ASKPASS:-}" ]] && rm -f "$_ASKPASS" 2>/dev/null || true
    unset _KYTH_BUILD_PW
}
trap cleanup EXIT

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
    "${ISO_DIR}/boot/grub2/themes/kyth" \
    "${ISO_DIR}/isolinux"

# ── 1. Build live container (shared cache with build-live-iso.sh) ─────────────
_need_rebuild=0
if [[ "${SKIP_REBUILD:-}" == "1" ]]; then
    echo "==> SKIP_REBUILD=1: using pre-built live container (CI mode)"
elif [[ "${REBUILD_IMAGE:-}" == "1" ]]; then
    echo "==> REBUILD_IMAGE=1: forcing live container rebuild"
    _need_rebuild=1
elif ! docker image inspect "${LIVE_BUILD_TAG}" >/dev/null 2>&1; then
    echo "==> ${LIVE_BUILD_TAG} not found: building live container variant"
    _need_rebuild=1
else
    _base_ts=$(docker image inspect "${LOCAL_BASE}" --format '{{.Created}}' 2>/dev/null || echo "")
    _live_ts=$(docker image inspect "${LIVE_BUILD_TAG}" --format '{{.Created}}' 2>/dev/null || echo "")
    if [[ -n "${_base_ts}" && "${_base_ts}" > "${_live_ts}" ]]; then
        echo "==> Base image newer than live container — rebuilding"
        _need_rebuild=1
    else
        echo "==> ${LIVE_BUILD_TAG} is up to date — skipping live container rebuild"
    fi
fi

if [[ "${_need_rebuild}" == "1" ]]; then
    echo "==> Building live container variant..."
    docker build \
        --build-arg BASE_IMAGE="${LOCAL_BASE}" \
        -f "${SCRIPT_DIR}/Containerfile.live" \
        -t "${LIVE_BUILD_TAG}" \
        "${REPO_ROOT}"
    echo "==> Live container build complete"
fi

# ── 2. Export container filesystem ───────────────────────────────────────────
echo "==> Exporting container filesystem to ${ROOTFS}..."
CONTAINER=$(docker create "${LIVE_BUILD_TAG}" /bin/true)
if command -v pv >/dev/null 2>&1; then
    docker export "${CONTAINER}" | pv | \
        sudo tar -xC "${ROOTFS}" \
            --exclude='proc/*' --exclude='sys/*' \
            --exclude='dev/*' --exclude='run/*' \
            2> >(grep -v 'xattr' >&2)
else
    docker export "${CONTAINER}" | \
        sudo tar -xC "${ROOTFS}" \
            --exclude='proc/*' --exclude='sys/*' \
            --exclude='dev/*' --exclude='run/*' \
            2> >(grep -v 'xattr' >&2)
fi
echo "==> Container export complete."
docker rm "${CONTAINER}"

# ── 3. Kernel + live initramfs ────────────────────────────────────────────────
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

# ── 3b. Write source-imgref (replaces OCI bundle in the offline ISO) ──────────
# kyth-bootcinstall reads this file and pulls from the registry at install time.
echo "==> Writing network install source ref: ${SOURCE_IMGREF}"
sudo mkdir -p "${ROOTFS}/usr/share/kyth"
echo "${SOURCE_IMGREF}" | sudo tee "${ROOTFS}/usr/share/kyth/source-imgref" > /dev/null

# ── 4. Squashfs ───────────────────────────────────────────────────────────────
echo "==> Creating squashfs (zstd, $(nproc) cores)"
sudo mksquashfs "${ROOTFS}" "${ISO_DIR}/LiveOS/squashfs.img" \
    -comp zstd \
    -Xcompression-level 9 \
    -processors "$(nproc)" \
    -noappend \
    -no-progress \
    -no-xattrs \
    -e proc -e sys -e dev -e run

# ── 5a. GRUB config + dark theme ─────────────────────────────────────────────
echo "==> Writing GRUB config and theme"
LIVE_ARGS="root=live:CDLABEL=${VOLID} rd.live.image selinux=0 quiet splash"

cat > "${ISO_DIR}/boot/grub2/themes/kyth/theme.txt" <<THEMEEOF
# Kyth GRUB2 dark theme

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
    text   = "KYTH 43 — NETWORK INSTALL"
    font   = "DejaVu Sans Bold 28"
    color  = "#61afef"
    align  = "center"
}
THEMEEOF

for src_font in \
    "${ROOTFS}/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf" \
    "${ROOTFS}/usr/share/fonts/dejavu/DejaVuSans.ttf"; do
    if [[ -f "${src_font}" ]]; then
        grub2-mkfont -s 14 -o "${ISO_DIR}/boot/grub2/themes/kyth/dejavusans14.pf2"     "${src_font}" 2>/dev/null || true
        grub2-mkfont -s 28 -o "${ISO_DIR}/boot/grub2/themes/kyth/dejavusansbold28.pf2" "${src_font}" 2>/dev/null || true
        break
    fi
done

for unicode_src in \
    "${ROOTFS}/usr/share/grub/unicode.pf2" \
    "${ROOTFS}/boot/grub2/fonts/unicode.pf2" \
    "/usr/share/grub/unicode.pf2"; do
    if [[ -f "${unicode_src}" ]]; then
        cp "${unicode_src}" "${ISO_DIR}/boot/grub2/unicode.pf2" 2>/dev/null
        break
    fi
done

cat > "${ISO_DIR}/boot/grub2/grub.cfg" << GRUBEOF
set default=0
set timeout=10

insmod all_video
insmod gfxterm
insmod gfxmenu
insmod png

if loadfont /boot/grub2/unicode.pf2; then
    set gfxmode=auto
    terminal_output gfxterm
    loadfont /boot/grub2/themes/kyth/dejavusans14.pf2 || true
    loadfont /boot/grub2/themes/kyth/dejavusansbold28.pf2 || true
    set theme=/boot/grub2/themes/kyth/theme.txt
else
    set color_normal=light-gray/black
    set color_highlight=black/light-cyan
    set menu_color_normal=light-gray/black
    set menu_color_highlight=black/light-cyan
fi

menuentry "Install Kyth (network — requires internet)" --class fedora --class gnu-linux --class os {
    linux /images/pxeboot/vmlinuz ${LIVE_ARGS}
    initrd /images/pxeboot/initrd.img
}

menuentry "Check media and install Kyth (network)" --class fedora --class gnu-linux --class os {
    linux /images/pxeboot/vmlinuz ${LIVE_ARGS} rd.live.check
    initrd /images/pxeboot/initrd.img
}
GRUBEOF

cp "${ISO_DIR}/boot/grub2/grub.cfg" "${ISO_DIR}/EFI/BOOT/grub.cfg"

# ── 5b. UEFI EFI boot image ───────────────────────────────────────────────────
echo "==> Creating UEFI EFI boot image"
GRUB_EFI_BUILT=false
GRUB_X64_MODS="/usr/lib/grub/x86_64-efi"
if [[ ! -d "${GRUB_X64_MODS}" && -d "${ROOTFS}/usr/lib/grub/x86_64-efi" ]]; then
    GRUB_X64_MODS="${ROOTFS}/usr/lib/grub/x86_64-efi"
fi

if [[ -d "${GRUB_X64_MODS}" ]] && command -v grub2-mkimage &>/dev/null; then
    GRUB_EMBED_CFG="${WORK}/grub-efi-embed.cfg"
    cat > "${GRUB_EMBED_CFG}" << 'EMBEDEOF'
search --no-floppy --label --set=root Kyth-43-NetInst
set prefix=($root)/boot/grub2
source ($root)/boot/grub2/grub.cfg
EMBEDEOF

    grub2-mkimage \
        -O x86_64-efi \
        -o "${ISO_DIR}/EFI/BOOT/BOOTX64.EFI" \
        -p /boot/grub2 \
        -c "${GRUB_EMBED_CFG}" \
        -d "${GRUB_X64_MODS}" \
        linux normal iso9660 search search_label all_video gfxterm gfxmenu \
        png echo test ls part_gpt part_msdos fat
    GRUB_EFI_BUILT=true
    echo "    UEFI EFI binary: built with grub2-mkimage"
else
    echo "ERROR: Cannot build BOOTX64.EFI — grub2-mkimage or x86_64-efi modules not found." >&2
    echo "       Install on host: sudo dnf install grub2-tools-minimal" >&2
    exit 1
fi

EFI_IMG="${ISO_DIR}/images/efiboot.img"
truncate -s 15M "${EFI_IMG}"
mkfs.fat -n "EFIBOOT" "${EFI_IMG}"
mmd  -i "${EFI_IMG}" ::/EFI ::/EFI/BOOT
if [[ "${GRUB_EFI_BUILT}" == "true" ]]; then
    mcopy -i "${EFI_IMG}" "${ISO_DIR}/EFI/BOOT/BOOTX64.EFI" ::/EFI/BOOT/BOOTX64.EFI
fi
mcopy -i "${EFI_IMG}" "${ISO_DIR}/EFI/BOOT/grub.cfg" ::/EFI/BOOT/grub.cfg

cat > "${ISO_DIR}/startup.nsh" << 'NSHEOF'
@echo -off
echo Booting Kyth Network Installer...
fs0:\EFI\BOOT\BOOTX64.EFI
NSHEOF

# ── 5c. BIOS boot ─────────────────────────────────────────────────────────────
echo "==> Setting up BIOS boot"
HAVE_ISOLINUX=false
HAVE_BIOS_GRUB=false

GRUB_I386_MODS="${ROOTFS}/usr/lib/grub/i386-pc"
if [[ -d "${GRUB_I386_MODS}" ]] && command -v grub2-mkimage &>/dev/null; then
    BIOS_IMG="${ISO_DIR}/boot/grub2/bios.img"
    grub2-mkimage \
        -O i386-pc-eltorito \
        -o "${BIOS_IMG}" \
        -p /boot/grub2 \
        -d "${GRUB_I386_MODS}" \
        linux normal iso9660 biosdisk all_video gfxterm gfxmenu png echo test ls
    HAVE_BIOS_GRUB=true
    echo "    GRUB2 BIOS boot image: OK"
fi

ISOLINUX_BIN="${ROOTFS}/usr/share/syslinux/isolinux.bin"
if ! "${HAVE_BIOS_GRUB}" && sudo test -f "${ISOLINUX_BIN}"; then
    echo "    Falling back to syslinux"
    sudo cp "${ISOLINUX_BIN}" "${ISO_DIR}/isolinux/"
    for f in ldlinux.c32 vesamenu.c32 libcom32.c32 libutil.c32; do
        src="${ROOTFS}/usr/share/syslinux/${f}"
        sudo test -f "${src}" && sudo cp "${src}" "${ISO_DIR}/isolinux/" || true
    done
    cat > "${ISO_DIR}/isolinux/isolinux.cfg" << ISOLINUXEOF
default vesamenu.c32
timeout 100
menu title Kyth 43 Network Installer

label live
  menu label Install Kyth (network)
  kernel /images/pxeboot/vmlinuz
  append initrd=/images/pxeboot/initrd.img ${LIVE_ARGS}
ISOLINUXEOF
    HAVE_ISOLINUX=true
fi

# ── 6. Assemble ISO ───────────────────────────────────────────────────────────
echo "==> Assembling ISO: ${OUTPUT_DIR}/${ISO_NAME}"
sudo mkdir -p "${OUTPUT_DIR}"
sudo chown "$(id -u):$(id -g)" "${OUTPUT_DIR}"

XORRISO_ARGS=(
    -as mkisofs
    -o "${OUTPUT_DIR}/${ISO_NAME}"
    -V "${VOLID}"
    -iso-level 3
    -R -J -joliet-long
)

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
echo "==> Network install ISO ready"
echo "    ${ISO_PATH} (${ISO_SIZE})"
echo "    Pulls from: ${SOURCE_IMGREF}"
