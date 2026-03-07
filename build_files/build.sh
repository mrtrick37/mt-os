#!/bin/bash

set -ouex pipefail

### CachyOS kernel — replaces the stock Fedora kernel for better desktop/gaming performance
# CachyOS COPR: https://copr.fedorainfracloud.org/coprs/bieszczaders/kernel-cachyos/
dnf5 copr enable -y bieszczaders/kernel-cachyos

# Install CachyOS kernel packages
dnf5 install -y \
    kernel-cachyos \
    kernel-cachyos-core \
    kernel-cachyos-modules \
    kernel-cachyos-modules-core \
    kernel-cachyos-modules-extra \
    kernel-cachyos-headers

# Remove the stock Fedora kernel so CachyOS is the only (and thus default) kernel
# This keeps the image lean and avoids grub confusion at boot
rpm -qa | grep -E '^kernel-(core|modules|modules-core|modules-extra|devel)?-[0-9]' | grep -v cachyos | xargs -r dnf5 remove -y || true
rpm -qa | grep -E '^kernel-[0-9]' | grep -v cachyos | xargs -r dnf5 remove -y || true

# Disable COPR after install
dnf5 copr disable -y bieszczaders/kernel-cachyos

### Install packages

# Packages can be installed from any enabled yum repo on the image.
# RPMfusion repos are available by default in ublue main images
# List of rpmfusion packages can be found here:
# https://mirrors.rpmfusion.org/mirrorlist?path=free/fedora/updates/43/x86_64/repoview/index.html&protocol=https&redirect=1

# Fedora packages (DX tooling — mirrors bluefin-dx)
dnf5 install -y \
    android-tools \
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

# Enable COPRs for gaming packages
dnf5 copr enable -y ublue-os/bazzite
dnf5 copr enable -y ublue-os/bazzite-multilib
dnf5 copr enable -y ublue-os/staging
dnf5 copr enable -y ublue-os/packages
dnf5 copr enable -y ublue-os/obs-vkcapture
dnf5 copr enable -y ycollet/audinux

# negativo17 Steam repo
dnf5 config-manager addrepo --from-repofile=https://negativo17.org/repos/fedora-steam.repo

# Gaming packages
dnf5 install -y \
    gamescope \
    gamescope-libs.x86_64 \
    gamescope-libs.i686 \
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
    gamescope-session

# KDE-specific gaming integrations
dnf5 install -y \
    kdeconnectd \
    kdeplasma-addons \
    rom-properties-kf6

# Download winetricks from upstream (package version is often outdated)
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

# Docker CE (repo added but disabled by default — install with --enablerepo=docker-ce-stable)
dnf5 config-manager addrepo --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo
sed -i "s/enabled=.*/enabled=0/g" /etc/yum.repos.d/docker-ce.repo
dnf5 -y install --enablerepo=docker-ce-stable \
    containerd.io \
    docker-buildx-plugin \
    docker-ce \
    docker-ce-cli \
    docker-compose-plugin

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

systemctl enable docker.socket
systemctl enable podman.socket
systemctl enable libvirtd.socket

# Ensure the built image advertises the mt-OS product name. Some boot/installer
# menus derive their display strings from `/etc/os-release` or similar metadata.
# We overwrite or create `/etc/os-release` with mt-OS values so boot menus show
# "mt-OS" instead of upstream branding.
cat > /etc/os-release <<'EOF' || true
NAME="mt-OS"
PRETTY_NAME="mt-OS 43"
ID=fedora
VERSION="43"
VERSION_ID="43"
ANSI_COLOR="0;34"
HOME_URL="https://example.com/mt-os"
SUPPORT_URL="https://example.com/mt-os/support"
BUG_REPORT_URL="https://example.com/mt-os/issues"
EOF

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
