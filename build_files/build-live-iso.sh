#!/usr/bin/env bash

# build-live-iso.sh — Build a live desktop ISO for KythOS with the web installer.
#
# Flow:
#   1. Build Containerfile.live (stable live environment + Chromium + kyth-installer)
#   2. Export the container filesystem to a temporary rootfs
#   3. Copy kernel + live initramfs out of the rootfs
#   4. mksquashfs the rootfs → LiveOS/squashfs.img
#   5. Assemble bootable ISO: UEFI (GRUB2) + BIOS (syslinux) via xorriso
#
# No OCI bundle is embedded — the OS is pulled from the registry at install
# time by kyth-installer via bootc install to-disk.
#
# Host requirements:
#   xorriso, squashfs-tools (mksquashfs), mtools, dosfstools
#   (all available via: sudo dnf install xorriso squashfs-tools mtools dosfstools)

set -euo pipefail

# ── Docker group bootstrap ─────────────────────────────────────────────────────
# If docker is inaccessible, add the user to the docker group (if needed) and
# re-exec under `sg docker` to activate it — no logout required.
if ! docker info &>/dev/null 2>&1; then
    if ! id -nG "$USER" | grep -qw docker; then
        echo "==> Adding ${USER} to the docker group (requires sudo)..."
        command sudo usermod -aG docker "$USER"
    fi
    echo "==> Activating docker group for this session via sg — restarting build..."
    exec sg docker -c "bash $(printf '%q' "${BASH_SOURCE[0]}")"
    echo "ERROR: Could not activate the docker group. Try: newgrp docker" >&2
    exit 1
fi

SOURCE_TAG="${SOURCE_TAG:-latest}"
INSTALLER_BASE_IMAGE="${INSTALLER_BASE_IMAGE:-ghcr.io/ublue-os/kinoite-main:43}"
if [[ "${SOURCE_TAG}" == "latest" ]]; then
    LIVE_BUILD_TAG="kyth-live:build"
else
    LIVE_BUILD_TAG="kyth-live:build-${SOURCE_TAG}"
fi

# ── Sudo setup: ask once, work fully unattended for the rest of the build ─────
if command sudo -n true 2>/dev/null; then
    _ASKPASS=""
else
    IFS= read -rsp "Enter sudo password (needed for export, squashfs, and ISO assembly): " _build_pw
    echo
    printf '%s\n' "$_build_pw" | command sudo -S true 2>/dev/null \
        || { echo "error: incorrect sudo password"; exit 1; }
    export _KYTH_BUILD_PW="$_build_pw"
    unset _build_pw
    _ASKPASS=$(mktemp -p /var/tmp kyth-build-askpass.XXXXXXXX)
    chmod 0700 "$_ASKPASS"
    printf '#!/bin/sh\nprintf "%%s\\n" "$_KYTH_BUILD_PW"\n' > "$_ASKPASS"
    export SUDO_ASKPASS="$_ASKPASS"
    sudo() { command sudo -A "$@"; }
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTPUT_DIR="${REPO_ROOT}/output/live-iso"
ISO_NAME="kyth-live-${SOURCE_TAG}.iso"
VOLID="KythOS-43-Live"

# Hash relevant installer sources so cached container rebuilds when these files
# change (even if the base image timestamp does not).
SOURCE_HASH="$(
    cd "${REPO_ROOT}"
    sha256sum \
        build_files/Containerfile.live \
        build_files/kyth-installer \
        build_files/kyth-launch-installer \
        build_files/plymouth/kyth.plymouth \
        build_files/plymouth/kyth.script \
        build_files/wallpaper/kyth-wallpaper.svg \
        build_files/branding/kyth-logo.svg \
    | sha256sum \
    | awk '{print $1}'
)"

TMPDIR_BASE="${TMPDIR:-/var/tmp}"
WORK=$(mktemp -d -p "${TMPDIR_BASE}" kyth-live.XXXXXXXXXX)
ROOTFS="${WORK}/rootfs"
ISO_DIR="${WORK}/iso"

if ! command -v docker &>/dev/null; then
    echo "ERROR: docker not found — install Docker or add it to PATH." >&2
    exit 1
fi
echo "==> Using container engine: docker"
echo "==> Installer runtime base image: ${INSTALLER_BASE_IMAGE}"

echo "==> Pulling installer runtime base image..."
if ! docker pull "${INSTALLER_BASE_IMAGE}"; then
    echo "ERROR: Failed to pull installer runtime base image: ${INSTALLER_BASE_IMAGE}" >&2
    exit 1
fi

cleanup() {
    echo "==> Cleaning up ${WORK}"
    sudo rm -rf "${WORK}" 2>/dev/null || true
    [[ -n "${_ASKPASS:-}" ]] && rm -f "$_ASKPASS" 2>/dev/null || true
    unset _KYTH_BUILD_PW
    # kyth-live:build is kept intentionally so Docker layer cache is preserved
    # for the next build. Run 'docker rmi kyth-live:build' to force a rebuild.
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

# ── 1. Build live container ─────────────────────────────────────────
_need_rebuild=0
if [[ "${SKIP_REBUILD:-}" == "1" ]]; then
    echo "==> SKIP_REBUILD=1: using pre-built live container (CI mode)"
elif [[ "${REBUILD_IMAGE:-}" == "1" ]]; then
    echo "==> REBUILD_IMAGE=1: forcing live container rebuild"
    _need_rebuild=1
elif ! docker image inspect "${LIVE_BUILD_TAG}" >/dev/null 2>&1; then
    echo "==> ${LIVE_BUILD_TAG} not found: building live container"
    _need_rebuild=1
else
    _installed_hash=$(docker image inspect "${LIVE_BUILD_TAG}" \
        --format '{{ index .Config.Labels "org.kyth.live.source-hash" }}' \
        2>/dev/null || echo "")
    if [[ "${_installed_hash}" != "${SOURCE_HASH}" ]]; then
        echo "==> Installer sources changed — rebuilding ${LIVE_BUILD_TAG}..."
        _need_rebuild=1
    fi

    _base_ts=$(docker image inspect "${INSTALLER_BASE_IMAGE}" \
        --format '{{.Created}}' 2>/dev/null || echo "")
    _live_ts=$(docker image inspect "${LIVE_BUILD_TAG}" \
        --format '{{.Created}}' 2>/dev/null || echo "")
    if [[ -n "${_base_ts}" && "${_base_ts}" > "${_live_ts}" ]]; then
        echo "==> Base image has changed — rebuilding ${LIVE_BUILD_TAG}..."
        _need_rebuild=1
    else
        echo "==> ${LIVE_BUILD_TAG} is up to date — skipping rebuild"
    fi
fi

if [[ "${_need_rebuild}" == "1" ]]; then
    echo "==> Building live container (this takes a while)..."
    docker build \
        --build-arg BASE_IMAGE="${INSTALLER_BASE_IMAGE}" \
        --build-arg SOURCE_HASH="${SOURCE_HASH}" \
        --build-arg SOURCE_TAG="${SOURCE_TAG}" \
        -f "${SCRIPT_DIR}/Containerfile.live" \
        -t "${LIVE_BUILD_TAG}" \
        "${REPO_ROOT}"
    echo "==> Live container build complete"
fi

# ── 2. Export container filesystem ───────────────────────────────────────────
echo "==> Exporting container filesystem to ${ROOTFS}"
CONTAINER=$(docker create "${LIVE_BUILD_TAG}" /bin/true)
if command -v pv >/dev/null 2>&1; then
    docker export "${CONTAINER}" | pv | \
        sudo tar -xC "${ROOTFS}" \
            --exclude='proc/*' \
            --exclude='sys/*' \
            --exclude='dev/*' \
            --exclude='run/*' \
            2>/dev/null
else
    docker export "${CONTAINER}" | \
        sudo tar -xC "${ROOTFS}" \
            --exclude='proc/*' \
            --exclude='sys/*' \
            --exclude='dev/*' \
            --exclude='run/*' \
            2>/dev/null
fi
echo "==> Container export complete."
docker rm "${CONTAINER}"

# ── 3. Kernel + live initramfs ───────────────────────────────────────────────
echo "==> Locating kernel and live initramfs"
KVER=$(
    find "${ROOTFS}/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
        | sort -V \
        | tail -n 1
)
echo "    Kernel: ${KVER}"

VMLINUZ="${ROOTFS}/usr/lib/modules/${KVER}/vmlinuz"
INITRD="${ROOTFS}/usr/lib/modules/${KVER}/initramfs-live"

[[ -f "${VMLINUZ}" ]] || { echo "ERROR: vmlinuz not found at ${VMLINUZ}" >&2; exit 1; }
[[ -f "${INITRD}"  ]] || { echo "ERROR: live initramfs not found at ${INITRD}" >&2; exit 1; }

sudo cp "${VMLINUZ}" "${ISO_DIR}/images/pxeboot/vmlinuz" 2>/dev/null
sudo cp "${INITRD}"  "${ISO_DIR}/images/pxeboot/initrd.img" 2>/dev/null
sudo chmod 644 "${ISO_DIR}/images/pxeboot/"*

# ── 4. Squashfs ───────────────────────────────────────────────────────────────
# No OCI bundle embedded — kyth-installer pulls from the registry at install time
# via bootc install to-disk.
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
LIVE_ARGS="quiet rhgb rd.plymouth=1 plymouth.enable=1 plymouth.ignore-serial-consoles root=live:CDLABEL=${VOLID} rd.live.image rd.retry=60 enforcing=0 systemd.crash_reboot=0 inst.nokill console=ttyS0,115200 console=tty0"

cat > "${ISO_DIR}/boot/grub2/themes/kyth/theme.txt" <<THEMEEOF
# KythOS GRUB2 dark theme

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
    text   = "KYTH 43"
    font   = "DejaVu Sans Bold 28"
    color  = "#61afef"
    align  = "center"
}
THEMEEOF

for src_font in \
    "${ROOTFS}/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf" \
    "${ROOTFS}/usr/share/fonts/dejavu/DejaVuSans.ttf"; do
    if [[ -f "${src_font}" ]]; then
        grub2-mkfont -s 14 -o "${ISO_DIR}/boot/grub2/themes/kyth/dejavusans14.pf2" "${src_font}" 2>/dev/null || true
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

# ── Graphical terminal + dark theme ───────────────────────────────────────────
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

# ── Boot entries ───────────────────────────────────────────────────────────────
menuentry "Try KythOS Live" --class fedora --class gnu-linux --class os {
    linux /images/pxeboot/vmlinuz ${LIVE_ARGS}
    initrd /images/pxeboot/initrd.img
}

menuentry "Try KythOS Live (Hardware GL Test)" --class fedora --class gnu-linux --class os {
    linux /images/pxeboot/vmlinuz ${LIVE_ARGS} kyth.live.hwgl=1 kyth.installer.hwgl=1
    initrd /images/pxeboot/initrd.img
}

menuentry "Try KythOS Live (Debug — verbose boot)" --class fedora --class gnu-linux --class os {
    linux /images/pxeboot/vmlinuz rd.plymouth=0 plymouth.enable=0 root=live:CDLABEL=${VOLID} rd.live.image rd.retry=60 enforcing=0 systemd.crash_reboot=0 rd.debug loglevel=7 console=ttyS0,115200 console=tty0
    initrd /images/pxeboot/initrd.img
}

GRUBEOF

cp "${ISO_DIR}/boot/grub2/grub.cfg" "${ISO_DIR}/EFI/BOOT/grub.cfg" 2>/dev/null

# ── 5b. UEFI EFI boot image (FAT) ────────────────────────────────────────────
echo "==> Creating UEFI EFI boot image"

GRUB_EFI_BUILT=false
GRUB_X64_MODS="/usr/lib/grub/x86_64-efi"
if [[ ! -d "${GRUB_X64_MODS}" && -d "${ROOTFS}/usr/lib/grub/x86_64-efi" ]]; then
    GRUB_X64_MODS="${ROOTFS}/usr/lib/grub/x86_64-efi"
fi

if [[ -d "${GRUB_X64_MODS}" ]] && command -v grub2-mkimage &>/dev/null; then
    GRUB_EMBED_CFG="${WORK}/grub-efi-embed.cfg"
    cat > "${GRUB_EMBED_CFG}" << 'EMBEDEOF'
search --no-floppy --label --set=root KythOS-43-Live
set prefix=($root)/boot/grub2
source ($root)/boot/grub2/grub.cfg
EMBEDEOF

    grub2-mkimage \
        -O x86_64-efi \
        -o "${ISO_DIR}/EFI/BOOT/grubx64.efi" \
        -p /boot/grub2 \
        -c "${GRUB_EMBED_CFG}" \
        -d "${GRUB_X64_MODS}" \
        linux normal iso9660 search search_label all_video gfxterm gfxmenu \
        efi_gop efi_uga font loopback chain \
        png echo test ls part_gpt part_msdos fat
    GRUB_EFI_BUILT=true
    echo "    UEFI GRUB binary: built with grub2-mkimage (x86_64-efi) → grubx64.efi"

    # Secure Boot: use Fedora-signed shim as BOOTX64.EFI.
    # The shim chainloads grubx64.efi from the same directory.
    SHIM_SRC=""
    for shim_path in \
        "${ROOTFS}/boot/efi/EFI/fedora/shimx64.efi" \
        "${ROOTFS}/usr/share/shim/*/shimx64.efi"; do
        if [[ -f "${shim_path}" ]]; then
            SHIM_SRC="${shim_path}"
            break
        fi
    done
    if [[ -n "${SHIM_SRC}" ]]; then
        cp "${SHIM_SRC}" "${ISO_DIR}/EFI/BOOT/BOOTX64.EFI"
        echo "    Secure Boot shim: ${SHIM_SRC} → BOOTX64.EFI"
        # Also copy the Fedora CA fallback (mmx64.efi) if present
        SHIM_DIR="$(dirname "${SHIM_SRC}")"
        if [[ -f "${SHIM_DIR}/mmx64.efi" ]]; then
            cp "${SHIM_DIR}/mmx64.efi" "${ISO_DIR}/EFI/BOOT/mmx64.efi"
        fi
    else
        echo "WARNING: shimx64.efi not found in rootfs — falling back to unsigned boot." >&2
        echo "         Secure Boot must be disabled on the target machine." >&2
        cp "${ISO_DIR}/EFI/BOOT/grubx64.efi" "${ISO_DIR}/EFI/BOOT/BOOTX64.EFI"
    fi
else
    echo "ERROR: Cannot build BOOTX64.EFI — grub2-mkimage or x86_64-efi modules not found." >&2
    echo "       Install on host: sudo dnf install grub2-tools-minimal" >&2
    exit 1
fi

EFI_IMG="${ISO_DIR}/images/efiboot.img"
truncate -s 15M "${EFI_IMG}"
mkfs.fat -n "EFIBOOT" "${EFI_IMG}"
mmd  -i "${EFI_IMG}" ::/EFI ::/EFI/BOOT
mcopy -i "${EFI_IMG}" "${ISO_DIR}/EFI/BOOT/BOOTX64.EFI" ::/EFI/BOOT/BOOTX64.EFI
if [[ "${GRUB_EFI_BUILT}" == "true" ]]; then
    mcopy -i "${EFI_IMG}" "${ISO_DIR}/EFI/BOOT/grubx64.efi" ::/EFI/BOOT/grubx64.efi
fi
if [[ -f "${ISO_DIR}/EFI/BOOT/mmx64.efi" ]]; then
    mcopy -i "${EFI_IMG}" "${ISO_DIR}/EFI/BOOT/mmx64.efi" ::/EFI/BOOT/mmx64.efi
fi
mcopy -i "${EFI_IMG}" "${ISO_DIR}/EFI/BOOT/grub.cfg" ::/EFI/BOOT/grub.cfg

cat > "${ISO_DIR}/startup.nsh" << 'NSHEOF'
@echo -off
echo Booting KythOS...
fs0:\EFI\BOOT\BOOTX64.EFI
NSHEOF

# ── 5c. BIOS boot ────────────────────────────────────────────────────────────
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
fi

ISOLINUX_BIN="${ROOTFS}/usr/share/syslinux/isolinux.bin"
if ! "${HAVE_BIOS_GRUB}" && sudo test -f "${ISOLINUX_BIN}"; then
    echo "    Falling back to syslinux"
    sudo cp "${ISOLINUX_BIN}" "${ISO_DIR}/isolinux/" 2>/dev/null
    for f in ldlinux.c32 vesamenu.c32 libcom32.c32 libutil.c32; do
        src="${ROOTFS}/usr/share/syslinux/${f}"
        sudo test -f "${src}" && sudo cp "${src}" "${ISO_DIR}/isolinux/" 2>/dev/null || true
    done

    cat > "${ISO_DIR}/isolinux/isolinux.cfg" << ISOLINUXEOF
default vesamenu.c32
timeout 100
menu title KythOS 43 Live

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
  menu label Try KythOS Live
  kernel /images/pxeboot/vmlinuz
  append initrd=/images/pxeboot/initrd.img ${LIVE_ARGS}

label hwgl
  menu label Try KythOS Live (Hardware GL Test)
  kernel /images/pxeboot/vmlinuz
  append initrd=/images/pxeboot/initrd.img ${LIVE_ARGS} kyth.live.hwgl=1 kyth.installer.hwgl=1

ISOLINUXEOF
    HAVE_ISOLINUX=true
    echo "    syslinux: OK (fallback)"
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
echo "==> KythOS live ISO ready"
echo "    ${ISO_PATH} (${ISO_SIZE})"
