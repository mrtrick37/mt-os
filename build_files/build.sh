#!/bin/bash

set -ouex pipefail

### Pull all upstream package updates
# Exclude kernel packages — the stock kernel is replaced by CachyOS below,
# and upgrading it here would trigger dracut in the %posttrans scriptlet which
# fails in container builds (EXDEV cross-device rename via tmpfs /tmp).
# Exclude gamescope* — conflicts with Bazzite's gamescope-libs-ba147.
dnf5 upgrade -y --exclude='kernel*' --exclude='gamescope*'

### CachyOS kernel — replaces the stock Fedora kernel for better desktop/gaming performance
# CachyOS COPR: https://copr.fedorainfracloud.org/coprs/bieszczaders/kernel-cachyos/
dnf5 copr enable -y bieszczaders/kernel-cachyos

# Install kernel packages with --noscripts to skip the %posttrans that calls
# rpm-ostree kernel-install → dracut. That script fails in container builds
# because it creates temp files in /tmp (tmpfs) then tries to rename them to the
# overlay filesystem, hitting "Invalid cross-device link" (EXDEV). We do the
# initramfs generation ourselves below with full control over the environment.
dnf5 install -y --setopt=tsflags=noscripts kernel-cachyos-modules

CACHYOS_KVER=$(ls /usr/lib/modules/ | grep cachyos | head -1)
depmod -a "${CACHYOS_KVER}"

dnf5 install -y --setopt=tsflags=noscripts --skip-unavailable \
    kernel-cachyos \
    kernel-cachyos-core \
    kernel-cachyos-devel

# Run depmod again now that all module packages are installed
depmod -a "${CACHYOS_KVER}"

# Ensure vmlinuz is in the OSTree-expected location
# (kernel RPMs may put it in /boot; bootc needs it at /usr/lib/modules/<kver>/vmlinuz)
if [ ! -f "/usr/lib/modules/${CACHYOS_KVER}/vmlinuz" ]; then
    if [ -f "/boot/vmlinuz-${CACHYOS_KVER}" ]; then
        cp "/boot/vmlinuz-${CACHYOS_KVER}" "/usr/lib/modules/${CACHYOS_KVER}/vmlinuz"
    fi
fi

# Write dracut config before generating initramfs.
# Force the ostree dracut module — required for bootc/ostree deployments.
# Without this the initramfs cannot find or mount the root filesystem.
# dracut skips it during container builds because there is no live ostree
# deployment to auto-detect.
mkdir -p /etc/dracut.conf.d
cat > /etc/dracut.conf.d/99-mt-os.conf <<'DRACUTEOF'
add_dracutmodules+=" ostree "
# virtio_blk/virtio_scsi/ahci are built into the CachyOS kernel (=y),
# so add_drivers has no effect for them. Kept for documentation.
add_drivers+=" virtio_blk virtio_scsi virtio_pci nvme ahci "
DRACUTEOF

# Generate initramfs directly — all paths stay on the overlay filesystem so
# no cross-device link issues. TMPDIR=/var/tmp for safety.
# Output to "initramfs" — bootc/ostree expects this exact filename.
TMPDIR=/var/tmp dracut \
    --no-hostonly \
    --kver "${CACHYOS_KVER}" \
    --force \
    "/usr/lib/modules/${CACHYOS_KVER}/initramfs" \
    2> >(grep -Ev 'xattr|fail to copy' >&2)

# Remove the stock Fedora kernel so CachyOS is the only (and thus default) kernel.
# dnf5 refuses to remove kernel-core if it considers it the "running" kernel in
# the container build environment, so we remove the module directory directly and
# clean up the RPM DB with rpm --nodeps.
for OLD_KVER in $(ls /usr/lib/modules/ | grep -v "${CACHYOS_KVER}"); do
    rm -rf "/usr/lib/modules/${OLD_KVER}"
done
rpm -qa | grep -E '^kernel' | grep -v cachyos | xargs -r rpm --nodeps -e 2>/dev/null || true

# Disable COPR after install
dnf5 copr disable -y bieszczaders/kernel-cachyos

### Install packages

# Packages can be installed from any enabled yum repo on the image.
# RPMfusion repos are available by default in ublue main images
# List of rpmfusion packages can be found here:
# https://mirrors.rpmfusion.org/mirrorlist?path=free/fedora/updates/43/x86_64/repoview/index.html&protocol=https&redirect=1

# Fedora packages (DX tooling — mirrors bluefin-dx)
dnf5 install -y \
    bcc \
    bpftop \
    bpftrace \
    cascadia-code-fonts \
    cockpit-bridge \
    cockpit-machines \
    cockpit-networkmanager \
    cockpit-ostree \
    cockpit-podman \
    cockpit-selinux \
    cockpit-storaged \
    cockpit-system \
    dbus-x11 \
    edk2-ovmf \
    flatpak-builder \
    genisoimage \
    git-subtree \
    git-svn \
    iotop \
    libvirt \
    libvirt-nss \
    nicstat \
    numactl \
    osbuild-selinux \
    p7zip \
    p7zip-plugins \
    podman-compose \
    podman-machine \
    podman-tui \
    qemu \
    qemu-char-spice \
    qemu-device-display-virtio-gpu \
    qemu-device-display-virtio-vga \
    qemu-device-usb-redirect \
    qemu-img \
    qemu-system-x86-core \
    qemu-user-binfmt \
    qemu-user-static \
    rocm-hip \
    rocm-opencl \
    rocm-smi \
    sysprof \
    incus \
    incus-agent \
    lxc \
    tiptop \
    trace-cmd \
    udica \
    util-linux-script \
    virt-manager \
    virt-v2v \
    virt-viewer \
    ydotool \
    tmux

# Gaming tweaks — Bazzite-style
# Enable RPM Fusion (free + nonfree) for multimedia/gaming packages
dnf5 install -y \
    "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" \
    "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm"

# Install gamescope from Fedora/RPMFusion BEFORE enabling Bazzite COPR.
# The Bazzite COPR ships gamescope-libs-ba147 which conflicts with the stock
# gamescope package. Installing first pins us to the Fedora version.
dnf5 install -y gamescope

# Enable COPRs for gaming packages
dnf5 copr enable -y ublue-os/bazzite
dnf5 copr enable -y ublue-os/bazzite-multilib
dnf5 copr enable -y ublue-os/staging
dnf5 copr enable -y ublue-os/packages
dnf5 copr enable -y ublue-os/obs-vkcapture
dnf5 copr enable -y ycollet/audinux

# negativo17 Steam repo — --overwrite for idempotency (CI caches base layers)
dnf5 config-manager addrepo --overwrite --from-repofile=https://negativo17.org/repos/fedora-steam.repo

# Gaming packages
dnf5 install -y --skip-unavailable \
    gamescope-shaders \
    umu-launcher \
    mangohud.x86_64 \
    mangohud.i686 \
    vkBasalt.x86_64 \
    vkBasalt.i686 \
    libFAudio.x86_64 \
    libFAudio.i686 \
    libobs_vkcapture.x86_64 \
    libobs_glcapture.x86_64 \
    libobs_vkcapture.i686 \
    libobs_glcapture.i686 \
    openxr \
    xrandr \
    evtest \
    xdg-user-dirs \
    xdg-terminal-exec \
    steam \
    lutris \
    gamemode \
    gamemode.i686 \
    libXScrnSaver \
    libXScrnSaver.i686 \
    libxcb.i686 \
    libatomic \
    libatomic.i686 \
    mesa-libGL.i686 \
    mesa-dri-drivers.i686 \
    nss \
    nss.i686

# KDE-specific gaming integrations
dnf5 install -y \
    kdeconnectd \
    kdeplasma-addons \
    rom-properties-kf6

# Download winetricks from upstream (package version is often outdated)
# /usr/local symlinks to /var/usrlocal — ensure the target dir exists
mkdir -p /usr/local/bin
curl -sL https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks \
    -o /usr/local/bin/winetricks
chmod +x /usr/local/bin/winetricks

# Disable COPRs so they don't persist in the final image
dnf5 copr disable -y ublue-os/bazzite
dnf5 copr disable -y ublue-os/bazzite-multilib
dnf5 copr disable -y ublue-os/staging
dnf5 copr disable -y ublue-os/packages
dnf5 copr disable -y ublue-os/obs-vkcapture
dnf5 copr disable -y ycollet/audinux
sed -i "s/enabled=.*/enabled=0/g" /etc/yum.repos.d/fedora-steam.repo

# Brave Browser — replaces Firefox
dnf5 remove -y firefox || true
dnf5 config-manager addrepo --overwrite --from-repofile=https://brave-browser-rpm-release.s3.brave.com/brave-browser.repo
dnf5 install -y brave-browser
sed -i "s/enabled=.*/enabled=0/g" /etc/yum.repos.d/brave-browser.repo

# Visual Studio Code (repo added but disabled by default)
tee /etc/yum.repos.d/vscode.repo <<'REPOEOF'
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
REPOEOF
sed -i "s/enabled=.*/enabled=0/g" /etc/yum.repos.d/vscode.repo
dnf5 -y install --enablerepo=code code

# Steam: disable CEF browser sandbox — required on bootc/ostree systems where
# user namespace restrictions prevent the Chromium sandbox from initialising,
# causing steamwebhelper to SEGV at startup.
mkdir -p /etc/environment.d
echo 'STEAM_DISABLE_BROWSER_SANDBOX=1' > /etc/environment.d/steam.conf

systemctl enable podman.socket
systemctl enable libvirtd.socket

# Homebrew — system-wide install to /home/linuxbrew (= /var/home/linuxbrew at runtime)
# Wheel group members can install/update formulae without sudo.
dnf5 install -y gcc glibc-devel libxcrypt-compat patch ruby
git clone https://github.com/Homebrew/brew /home/linuxbrew/.linuxbrew
# Make wheel group the owner so any wheel user can run brew
chown -R root:wheel /home/linuxbrew/.linuxbrew
chmod -R g+w /home/linuxbrew/.linuxbrew
find /home/linuxbrew/.linuxbrew -type d -exec chmod g+s {} \;
# Add brew to PATH for all login shells
cat > /etc/profile.d/homebrew.sh <<'BREWEOF'
if [ -d /home/linuxbrew/.linuxbrew ]; then
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
fi
BREWEOF
chmod +x /etc/profile.d/homebrew.sh

# Ensure the built image advertises the Forge product name. Some boot/installer
# menus derive their display strings from `/etc/os-release` or similar metadata.
# We overwrite or create `/etc/os-release` with Forge values so boot menus show
# "Forge" instead of upstream branding.
cat > /etc/os-release <<'EOF' || true
NAME="Forge"
PRETTY_NAME="Forge 43"
ID=fedora
VERSION="43"
VERSION_ID="43"
ANSI_COLOR="0;34"
HOME_URL="https://example.com/forge"
SUPPORT_URL="https://example.com/forge/support"
BUG_REPORT_URL="https://example.com/forge/issues"
EOF

# ── Forge Look-and-Feel package ───────────────────────────────────────────────
# Custom LnF that wraps Breeze Dark and sets a solid black wallpaper on ALL
# screens via a plasmoidsetupscripts JS file — this covers every containment
# ID regardless of how many monitors are connected.
LNF_DIR=/usr/share/plasma/look-and-feel/org.kde.forge
mkdir -p "${LNF_DIR}/contents/plasmoidsetupscripts"

cat > "${LNF_DIR}/metadata.json" <<'METAEOF'
{
    "KPackageStructure": "Plasma/LookAndFeel",
    "KPlugin": {
        "Authors": [{"Email": "", "Name": "Forge"}],
        "Description": "Forge — Breeze Dark with solid black wallpaper",
        "Id": "org.kde.forge",
        "Name": "Forge",
        "Version": "1.0"
    },
    "X-Plasma-API": "2.0"
}
METAEOF

cat > "${LNF_DIR}/contents/defaults" <<'DEFAULTSEOF'
[kdeglobals][General]
ColorScheme=BreezeDark

[kdeglobals][KDE]
widgetStyle=breeze

[Wallpaper]
wallpaperPlugin=org.kde.color
DEFAULTSEOF

# This script runs when the LnF is applied (first login / plasma-apply-lookandfeel).
# It iterates every desktop containment so all monitors get the black wallpaper.
cat > "${LNF_DIR}/contents/plasmoidsetupscripts/org.kde.plasma.desktop.js" <<'JSEOF'
var allDesktops = desktops();
for (var i = 0; i < allDesktops.length; i++) {
    var d = allDesktops[i];
    d.wallpaperPlugin = "org.kde.color";
    d.currentConfigGroup = ["Wallpaper", "org.kde.color", "General"];
    d.writeConfig("Color", "0,0,0,255");
}
JSEOF

# ── Default KDE theme for all new users via /etc/skel ─────────────────────────
mkdir -p /etc/skel/.config
cat > /etc/skel/.config/kdeglobals <<'KDEEOF'
[General]
ColorScheme=BreezeDark

[KDE]
LookAndFeelPackage=org.kde.forge
KDEEOF

cat > /etc/skel/.config/plasmarc <<'PLASMAEOF'
[Theme]
name=breeze-dark
PLASMAEOF

# ── First-login script: set Kickoff launcher icon to KDE logo ─────────────────
# Plasma assigns applet IDs dynamically, so we can't hardcode them in a config
# file. This autostart script runs once on first login, finds every kickoff
# applet in the appletsrc, sets its icon to the KDE logo, then removes itself.
mkdir -p /usr/local/bin
cat > /usr/local/bin/forge-set-kickoff-icon <<'KICKOFICONEOF'
#!/bin/bash
# Find all Kickoff applet sections in the appletsrc and set icon=kde (KDE logo).
APRC="${HOME}/.config/plasma-org.kde.plasma.desktop-appletsrc"
if [[ -f "$APRC" ]]; then
    while IFS= read -r section; do
        grp="${section//[\[\]]/}"
        kwriteconfig6 --file "$APRC" --group "$grp" \
            --subgroup "Configuration" --subgroup "General" \
            --key icon kde 2>/dev/null || true
    done < <(grep -B1 'plugin=org.kde.plasma.kickoff' "$APRC" | grep '^\[')
fi
# Remove self so it only runs once
rm -f "${HOME}/.config/autostart/forge-set-kickoff-icon.desktop"
KICKOFICONEOF
chmod +x /usr/local/bin/forge-set-kickoff-icon

mkdir -p /etc/skel/.config/autostart
cat > /etc/skel/.config/autostart/forge-set-kickoff-icon.desktop <<'AUTOSTARTEOF'
[Desktop Entry]
Type=Application
Name=Forge: Set Kickoff Icon
Exec=/usr/local/bin/forge-set-kickoff-icon
X-KDE-autostart-after=panel
Hidden=false
NoDisplay=true
AUTOSTARTEOF

# Seed containment 1 with the black wallpaper so it's set even before the
# LnF setup script runs on first login.
cat > /etc/skel/.config/plasma-org.kde.plasma.desktop-appletsrc <<'PLASMADESKTOPEOF'
[Containments][1]
wallpaperplugin=org.kde.color

[Containments][1][Wallpaper][org.kde.color][General]
Color=0,0,0,255
PLASMADESKTOPEOF

# Remove Waydroid desktop/menu entries and related files if present
# (some base images include a Waydroid helper that we don't ship in mt-OS)
rm -f /usr/share/applications/*waydroid*.desktop || true
rm -f /usr/local/share/applications/*waydroid*.desktop || true
rm -f /usr/share/kservices5/*waydroid* || true
rm -rf /usr/share/waydroid /var/lib/waydroid || true
# Also remove common capitalized filenames
rm -f /usr/share/applications/Waydroid.desktop || true

# QA check: fail the build if any Waydroid desktop/menu files remain
if find /usr/share/applications /usr/local/share/applications /usr/share/kservices5 -maxdepth 2 -type f -iname '*waydroid*' -print -quit | grep -q .; then
	echo "ERROR: Waydroid desktop/menu files remain after cleanup:" >&2
	find /usr/share/applications /usr/local/share/applications /usr/share/kservices5 -maxdepth 2 -type f -iname '*waydroid*' -print >&2 || true
	exit 1
fi
