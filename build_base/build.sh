#!/bin/bash
set -euo pipefail

# Docker build layers do not preserve security xattrs, so all files deployed
# via bootc/ostree end up unlabeled.  SELinux enforcing then denies access to
# unlabeled files, breaking dbus-broker and the entire session at first boot.
# Permissive mode logs denials without blocking — correct labeling requires
# either a Podman/buildah build (which preserves xattrs) or a live relabel.
sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config

# Apply Kyth branding to the base image
cat > /etc/os-release <<'EOF' || true
NAME="Kyth"
PRETTY_NAME="Kyth 43"
ID=fedora
VERSION_ID="43"
ANSI_COLOR="0;34"
HOME_URL="https://example.com/kyth"
SUPPORT_URL="https://example.com/kyth/support"
BUG_REPORT_URL="https://example.com/kyth/issues"
EOF

# Remove Waydroid artifacts if present
rm -f /usr/share/applications/*waydroid*.desktop || true
rm -f /usr/local/share/applications/*waydroid*.desktop || true
rm -f /usr/share/kservices5/*waydroid* || true
rm -rf /usr/share/waydroid /var/lib/waydroid || true

echo "Kyth base customization applied"

# --- CachyOS kernel installation (copied from build_files/build.sh) ---
echo "Installing CachyOS kernel..."
dnf5 copr enable -y bieszczaders/kernel-cachyos
dnf5 install -y --setopt=tsflags=noscripts kernel-cachyos-modules

CACHYOS_KVER=$(ls /usr/lib/modules/ | grep cachyos | head -1)
depmod -a "${CACHYOS_KVER}"

dnf5 install -y --setopt=tsflags=noscripts --skip-unavailable \
	kernel-cachyos \
	kernel-cachyos-core

depmod -a "${CACHYOS_KVER}"

# Remove every non-CachyOS kernel from /usr/lib/modules/ so bootc sees
# exactly one kernel (it errors out if multiple subdirectories are present).
echo "Removing non-CachyOS kernels from /usr/lib/modules/ ..."
for kdir in /usr/lib/modules/*/; do
    kver=$(basename "$kdir")
    if [[ "$kver" != *cachyos* ]]; then
        echo "  removing: $kver"
        rm -rf "$kdir"
    fi
done

# Ensure vmlinuz is in the OSTree-expected location
if [ ! -f "/usr/lib/modules/${CACHYOS_KVER}/vmlinuz" ]; then
	if [ -f "/boot/vmlinuz-${CACHYOS_KVER}" ]; then
		cp --no-preserve=all "/boot/vmlinuz-${CACHYOS_KVER}" "/usr/lib/modules/${CACHYOS_KVER}/vmlinuz" 2>/dev/null
	fi
fi

# Generate a standard disk-boot initramfs at the OSTree-expected location.
# tsflags=noscripts skipped dracut during kernel install, so we run it manually.
# This initramfs is used by bootc when installing the image to disk — without it
# the installed system kernel panics with "Unable to mount root fs on unknown-block(0,0)".
echo "Generating disk-boot initramfs for ${CACHYOS_KVER}..."
mkdir -p /etc/dracut.conf.d
cat > /etc/dracut.conf.d/99-kyth.conf <<'DRACUTEOF'
add_dracutmodules+=" ostree "
add_drivers+=" virtio_blk virtio_scsi virtio_pci nvme ahci "
DRACUTEOF
TMPDIR=/var/tmp dracut \
    --no-hostonly \
    --kver "${CACHYOS_KVER}" \
    --force \
    "/usr/lib/modules/${CACHYOS_KVER}/initramfs"
echo "initramfs generated at /usr/lib/modules/${CACHYOS_KVER}/initramfs"

# Set kernel args for the installed system via bootc kargs.d.
# quiet: suppress kernel log spam on the console.
# splash: activate Plymouth so the boot splash is shown.
mkdir -p /usr/lib/bootc/kargs.d
cat > /usr/lib/bootc/kargs.d/99-kyth.toml <<'KARGSEOF'
kargs = ["quiet", "splash"]
KARGSEOF

# ── SDDM — ensure graphical target ───────────────────────────────────────────
systemctl enable sddm 2>/dev/null || true
systemctl set-default graphical.target 2>/dev/null || true

# Mask bootloader-update.service: this ostree/rpm-ostree service tries to
# update the bootloader on every boot but always fails in our bootc image,
# producing noisy FAILED entries in the boot log.
systemctl mask bootloader-update.service 2>/dev/null || true

# ── SDDM display server: X11 default, Wayland on confirmed real hardware ─────
# X11 is baked in as the image default so SDDM always has a working config
# even if kyth-sddm-setup fails to run (e.g. during the D-Bus race at boot).
# kyth-sddm-setup then upgrades to Wayland only when systemd-detect-virt
# confirms the system is NOT a VM, giving the best experience on real hardware
# without risking a blank screen in VMs.
mkdir -p /etc/sddm.conf.d
cat > /etc/sddm.conf.d/10-display-server.conf <<'EOF'
[General]
DisplayServer=wayland

[Wayland]
SessionDir=/usr/share/wayland-sessions
CompositorCommand=kwin_wayland --no-global-shortcuts --no-lockscreen --locale1
EOF


# ── Kyth wallpaper ────────────────────────────────────────────────────────────
# Install the wallpaper and set it as the default for all new users via skel.
# KDE's org.kde.image plugin supports SVG natively — no PNG conversion needed.
WALLPAPER_DIR=/usr/share/wallpapers/kyth/contents/images
mkdir -p "${WALLPAPER_DIR}"

cat > "${WALLPAPER_DIR}/1920x1080.svg" <<'WALLPAPEREOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1920 1080" width="1920" height="1080">
  <defs>
    <filter id="logo-glow" x="-80%" y="-80%" width="260%" height="260%">
      <feGaussianBlur stdDeviation="28" result="blur"/>
      <feMerge><feMergeNode in="blur"/><feMergeNode in="SourceGraphic"/></feMerge>
    </filter>
    <filter id="spark-glow" x="-200%" y="-200%" width="500%" height="500%">
      <feGaussianBlur stdDeviation="32" result="blur"/>
      <feMerge><feMergeNode in="blur"/><feMergeNode in="SourceGraphic"/></feMerge>
    </filter>
  </defs>
  <rect width="1920" height="1080" fill="#000000"/>
  <g transform="translate(840, 367) scale(1.5)" filter="url(#logo-glow)">
    <line x1="54.6" y1="140.6" x2="54.6" y2="27.5" stroke="#7aa2f7" stroke-width="16.9" stroke-linecap="round"/>
    <circle cx="54.6" cy="17.2" r="12.5" fill="#7aa2f7"/>
    <line x1="122.5" y1="26.9" x2="54.6" y2="82.0" stroke="#bb9af7" stroke-width="16.9" stroke-linecap="round"/>
    <circle cx="130.6" cy="19.4" r="12.5" fill="#bb9af7"/>
    <line x1="122.5" y1="137.5" x2="54.6" y2="82.0" stroke="#73daca" stroke-width="16.9" stroke-linecap="round"/>
    <circle cx="130.6" cy="145.0" r="12.5" fill="#73daca"/>
    <circle cx="54.6" cy="82.0" r="10.0" fill="#e0af68" opacity="0.4" filter="url(#spark-glow)"/>
    <circle cx="54.6" cy="82.0" r="5.6" fill="#e0af68"/>
  </g>
  <text x="960" y="670" font-family="'DejaVu Sans','Liberation Sans',sans-serif" font-size="42" font-weight="300" letter-spacing="20" fill="#a9b1d6" opacity="0.8" text-anchor="middle">kyth</text>
</svg>
WALLPAPEREOF

cat > /usr/share/wallpapers/kyth/metadata.json <<'METAEOF'
{
  "KPlugin": {
    "Authors": [{"Name": "Kyth"}],
    "Id": "kyth",
    "Name": "Kyth",
    "License": "CC-BY-SA-4.0"
  },
  "KPackageStructure": "Wallpaper/Images"
}
METAEOF

# Default wallpaper for all new users via skel
mkdir -p /etc/skel/.config
cat > /etc/skel/.config/plasma-org.kde.plasma.desktop-appletsrc <<'SKELEOF'
[Containments][1]
wallpaperplugin=org.kde.image

[Containments][1][Wallpaper][org.kde.image][General]
Image=/usr/share/wallpapers/kyth/contents/images/1920x1080.svg
SKELEOF

