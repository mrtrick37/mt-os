#!/bin/bash
set -euo pipefail

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
	kernel-cachyos-core \
	kernel-cachyos-devel

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

# Disable Plymouth on the installed system — bootc inherits kernel args from
# the running live ISO (which includes 'quiet splash'), causing plymouthd to
# activate without a properly configured theme and hang the DRM handoff to SDDM.
# kargs.d entries are picked up by bootc install to-disk and written into the
# installed system's bootloader config.
mkdir -p /usr/lib/bootc/kargs.d
cat > /usr/lib/bootc/kargs.d/99-kyth.toml <<'KARGSEOF'
kargs = ["plymouth.enable=0"]
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
DisplayServer=x11

[X11]
SessionDir=/usr/share/xsessions
MinimumVT=1

[Wayland]
SessionDir=
EOF

mkdir -p /usr/lib/kyth
cat > /usr/lib/kyth/sddm-display-setup <<'SETUPEOF'
#!/bin/bash
# X11 is kept as the display server for both VMs and bare-metal installs.
# SDDM's Wayland greeter mode (DisplayServer=wayland) requires kwin_wayland to
# initialise successfully as a compositor, which fails silently on many GPU
# configurations and leaves a black screen at boot.  Users who want a Wayland
# KDE session can select "Plasma (Wayland)" from the SDDM session menu, or
# switch the default in KDE System Settings → Startup → Login Screen (SDDM).
if systemd-detect-virt -q 2>/dev/null; then
    echo "kyth-sddm-setup: VM detected, keeping X11 display server"
else
    echo "kyth-sddm-setup: bare-metal detected, keeping X11 display server"
fi
SETUPEOF
chmod +x /usr/lib/kyth/sddm-display-setup

cat > /usr/lib/systemd/system/kyth-sddm-setup.service <<'UNITEOF'
[Unit]
Description=Kyth: validate SDDM display server configuration
Before=sddm.service
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/lib/kyth/sddm-display-setup
RemainAfterExit=yes

[Install]
WantedBy=graphical.target
UNITEOF
systemctl enable kyth-sddm-setup.service 2>/dev/null || true

# ── Kyth wallpaper ────────────────────────────────────────────────────────────
# Install the wallpaper and set it as the default for all new users via skel.
# KDE's org.kde.image plugin supports SVG natively — no PNG conversion needed.
WALLPAPER_DIR=/usr/share/wallpapers/kyth/contents/images
mkdir -p "${WALLPAPER_DIR}"

cat > "${WALLPAPER_DIR}/1920x1080.svg" <<'WALLPAPEREOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1920 1080" width="1920" height="1080">
  <defs>
    <radialGradient id="bg" cx="45%" cy="55%" r="75%">
      <stop offset="0%"   stop-color="#1e2030"/>
      <stop offset="60%"  stop-color="#1a1b26"/>
      <stop offset="100%" stop-color="#13141e"/>
    </radialGradient>
    <filter id="logo-glow" x="-80%" y="-80%" width="260%" height="260%">
      <feGaussianBlur stdDeviation="22" result="blur"/>
      <feMerge><feMergeNode in="blur"/><feMergeNode in="SourceGraphic"/></feMerge>
    </filter>
    <filter id="spark-glow" x="-200%" y="-200%" width="500%" height="500%">
      <feGaussianBlur stdDeviation="28" result="blur"/>
      <feMerge><feMergeNode in="blur"/><feMergeNode in="SourceGraphic"/></feMerge>
    </filter>
    <radialGradient id="vignette" cx="50%" cy="50%" r="70%">
      <stop offset="0%"   stop-color="#000000" stop-opacity="0"/>
      <stop offset="100%" stop-color="#000000" stop-opacity="0.45"/>
    </radialGradient>
  </defs>
  <rect width="1920" height="1080" fill="url(#bg)"/>
  <g opacity="0.045" fill="#7aa2f7">
    <circle cx="160" cy="135" r="1.5"/><circle cx="320" cy="135" r="1.5"/><circle cx="480" cy="135" r="1.5"/><circle cx="640" cy="135" r="1.5"/><circle cx="800" cy="135" r="1.5"/><circle cx="960" cy="135" r="1.5"/><circle cx="1120" cy="135" r="1.5"/><circle cx="1280" cy="135" r="1.5"/><circle cx="1440" cy="135" r="1.5"/><circle cx="1600" cy="135" r="1.5"/><circle cx="1760" cy="135" r="1.5"/>
    <circle cx="160" cy="270" r="1.5"/><circle cx="320" cy="270" r="1.5"/><circle cx="480" cy="270" r="1.5"/><circle cx="640" cy="270" r="1.5"/><circle cx="800" cy="270" r="1.5"/><circle cx="960" cy="270" r="1.5"/><circle cx="1120" cy="270" r="1.5"/><circle cx="1280" cy="270" r="1.5"/><circle cx="1440" cy="270" r="1.5"/><circle cx="1600" cy="270" r="1.5"/><circle cx="1760" cy="270" r="1.5"/>
    <circle cx="160" cy="405" r="1.5"/><circle cx="320" cy="405" r="1.5"/><circle cx="480" cy="405" r="1.5"/><circle cx="640" cy="405" r="1.5"/><circle cx="800" cy="405" r="1.5"/><circle cx="960" cy="405" r="1.5"/><circle cx="1120" cy="405" r="1.5"/><circle cx="1280" cy="405" r="1.5"/><circle cx="1440" cy="405" r="1.5"/><circle cx="1600" cy="405" r="1.5"/><circle cx="1760" cy="405" r="1.5"/>
    <circle cx="160" cy="540" r="1.5"/><circle cx="320" cy="540" r="1.5"/><circle cx="480" cy="540" r="1.5"/><circle cx="640" cy="540" r="1.5"/><circle cx="800" cy="540" r="1.5"/><circle cx="960" cy="540" r="1.5"/><circle cx="1120" cy="540" r="1.5"/><circle cx="1280" cy="540" r="1.5"/><circle cx="1440" cy="540" r="1.5"/><circle cx="1600" cy="540" r="1.5"/><circle cx="1760" cy="540" r="1.5"/>
    <circle cx="160" cy="675" r="1.5"/><circle cx="320" cy="675" r="1.5"/><circle cx="480" cy="675" r="1.5"/><circle cx="640" cy="675" r="1.5"/><circle cx="800" cy="675" r="1.5"/><circle cx="960" cy="675" r="1.5"/><circle cx="1120" cy="675" r="1.5"/><circle cx="1280" cy="675" r="1.5"/><circle cx="1440" cy="675" r="1.5"/><circle cx="1600" cy="675" r="1.5"/><circle cx="1760" cy="675" r="1.5"/>
    <circle cx="160" cy="810" r="1.5"/><circle cx="320" cy="810" r="1.5"/><circle cx="480" cy="810" r="1.5"/><circle cx="640" cy="810" r="1.5"/><circle cx="800" cy="810" r="1.5"/><circle cx="960" cy="810" r="1.5"/><circle cx="1120" cy="810" r="1.5"/><circle cx="1280" cy="810" r="1.5"/><circle cx="1440" cy="810" r="1.5"/><circle cx="1600" cy="810" r="1.5"/><circle cx="1760" cy="810" r="1.5"/>
    <circle cx="160" cy="945" r="1.5"/><circle cx="320" cy="945" r="1.5"/><circle cx="480" cy="945" r="1.5"/><circle cx="640" cy="945" r="1.5"/><circle cx="800" cy="945" r="1.5"/><circle cx="960" cy="945" r="1.5"/><circle cx="1120" cy="945" r="1.5"/><circle cx="1280" cy="945" r="1.5"/><circle cx="1440" cy="945" r="1.5"/><circle cx="1600" cy="945" r="1.5"/><circle cx="1760" cy="945" r="1.5"/>
  </g>
  <polygon points="0,0 480,0 960,540 0,540"        fill="#7aa2f7" opacity="0.07"/>
  <polygon points="1920,0 1440,0 960,540 1920,540"  fill="#bb9af7" opacity="0.07"/>
  <polygon points="640,1080 1280,1080 960,540"       fill="#73daca" opacity="0.07"/>
  <line x1="0" y1="0" x2="960" y2="540"     stroke="#7aa2f7" stroke-width="1" opacity="0.2"/>
  <line x1="1920" y1="0" x2="960" y2="540"  stroke="#bb9af7" stroke-width="1" opacity="0.2"/>
  <line x1="960" y1="1080" x2="960" y2="540" stroke="#73daca" stroke-width="1" opacity="0.2"/>
  <g transform="translate(880, 440)" filter="url(#logo-glow)">
    <circle cx="80" cy="80" r="72" fill="#1e2030" opacity="0.7"/>
    <line x1="54.6" y1="140.6" x2="54.6" y2="27.5" stroke="#7aa2f7" stroke-width="16.9" stroke-linecap="round"/>
    <circle cx="54.6" cy="17.2" r="12.5" fill="#7aa2f7"/>
    <line x1="122.5" y1="26.9" x2="54.6" y2="82.0" stroke="#bb9af7" stroke-width="16.9" stroke-linecap="round"/>
    <circle cx="130.6" cy="19.4" r="12.5" fill="#bb9af7"/>
    <line x1="122.5" y1="137.5" x2="54.6" y2="82.0" stroke="#73daca" stroke-width="16.9" stroke-linecap="round"/>
    <circle cx="130.6" cy="145.0" r="12.5" fill="#73daca"/>
    <circle cx="54.6" cy="82.0" r="10.0" fill="#e0af68" opacity="0.35" filter="url(#spark-glow)"/>
    <circle cx="54.6" cy="82.0" r="5.6" fill="#e0af68"/>
  </g>
  <text x="960" y="650" font-family="'DejaVu Sans','Liberation Sans',sans-serif" font-size="38" font-weight="300" letter-spacing="18" fill="#a9b1d6" opacity="0.75" text-anchor="middle">kyth</text>
  <rect width="1920" height="1080" fill="url(#vignette)"/>
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
