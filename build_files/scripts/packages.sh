#!/bin/bash

set -euo pipefail

# ── Locale filtering ──────────────────────────────────────────────────────────
# Strip non-English locale data from every subsequent RPM install.
# Saves 100–300 MB across the full package set with no functional loss
# on an English workstation.
echo '%_install_langs en_US' >> /etc/rpm/macros

### Install Docker for container operations
dnf5 install -y docker || true

# Add rpmfusion free and nonfree repositories for Fedora 43
dnf5 install -y https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-43.noarch.rpm || true
dnf5 install -y https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-43.noarch.rpm || true

# ── Multimedia baseline ───────────────────────────────────────────────────────
# Install a full system codec stack so common local playback, browser media,
# and creator workflows work without extra setup.  RPM Fusion provides the
# patent-encumbered pieces Fedora does not ship by default.
dnf5 install -y --skip-unavailable \
    ffmpeg \
    ffmpegthumbnailer \
    gstreamer1-plugin-openh264 \
    gstreamer1-plugins-bad-freeworld \
    gstreamer1-plugins-ugly \
    gstreamer1-libav \
    mozilla-openh264 \
    mpv

# Install all required packages
dnf5 install -y --skip-unavailable \
    p7zip \
    p7zip-plugins \
    duperemove \
    qemu-char-spice \
    qemu-device-display-virtio-gpu \
    qemu-device-display-virtio-vga \
    qemu-device-usb-redirect \
    qemu-img \
    qemu-system-x86-core \
    sysprof \
    incus \
    incus-agent \
    lxc \
    tiptop \
    trace-cmd \
    util-linux-script \
    virt-viewer \
    gnome-boxes \
    ydotool \
    tmux \
    gh \
    fwupd

## Gaming tweaks — Bazzite-style
# Install gamescope from Fedora BEFORE enabling Bazzite COPR.

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
# libde265.i686 is excluded: it's an HEVC decoder pulled in transitively by Steam's
# 32-bit deps, but it's frequently unavailable on Fedora mirrors and is not needed.
dnf5 install -y --skip-unavailable --exclude=libde265.i686 \
    gamescope-shaders \
    umu-launcher \
    mangohud.x86_64 \
    mangohud.i686 \
    vkBasalt.x86_64 \
    vkBasalt.i686 \
    libFAudio.x86_64 \
    libFAudio.i686 \
    obs-studio \
    libobs_vkcapture.x86_64 \
    libobs_glcapture.x86_64 \
    libobs_vkcapture.i686 \
    libobs_glcapture.i686 \
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
    rom-properties-kf6 \
    input-remapper

is_enabled() {
    case "${1,,}" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

# ── system76-scheduler ────────────────────────────────────────────────────────
# Dynamically adjusts CFS nice values and I/O priority based on which window
# is focused and whether a game is running.  Gives a noticeable responsiveness
# boost during gaming without requiring per-app configuration.
if dnf5 repoquery --available system76-scheduler 2>/dev/null | grep -q .; then
  dnf5 install -y --skip-unavailable system76-scheduler || true
  rpm -q system76-scheduler >/dev/null 2>&1 && \
    systemctl enable com.system76.Scheduler 2>/dev/null || true
else
  echo "system76-scheduler is unavailable in configured repos; skipping."
fi

# ── ananicy-cpp process priority rules ───────────────────────────────────────
# Applies static per-process CPU/I/O priorities (browser, game launchers,
# compilers, etc.) to smooth desktop responsiveness under mixed load.
if is_enabled "${ENABLE_ANANICY:-1}"; then
    if dnf5 repoquery --available ananicy-cpp 2>/dev/null | grep -q .; then
        dnf5 install -y --skip-unavailable \
                ananicy-cpp \
                ananicy-cpp-rules \
                ananicy-cpp-rules-git || true
        rpm -q ananicy-cpp >/dev/null 2>&1 && \
            systemctl enable ananicy-cpp.service 2>/dev/null || true
    else
        echo "ananicy-cpp is unavailable in configured repos; skipping."
    fi
else
    echo "ENABLE_ANANICY is off; skipping ananicy-cpp install."
fi

# Disable COPRs so they don't persist in the final image
dnf5 copr disable -y ublue-os/bazzite
dnf5 copr disable -y ublue-os/bazzite-multilib
dnf5 copr disable -y ublue-os/staging
dnf5 copr disable -y ublue-os/packages
dnf5 copr disable -y ublue-os/obs-vkcapture
dnf5 copr disable -y ycollet/audinux
sed -i "s/enabled=.*/enabled=0/g" /etc/yum.repos.d/fedora-steam.repo

### GPU drivers


# ── AMD ───────────────────────────────────────────────────────────────────────
# amdgpu is in the CachyOS kernel; RADV (Vulkan) comes from mesa (Fedora repos).
# linux-firmware provides the GPU firmware blobs that amdgpu loads at runtime —
# without them the driver falls back to basic/non-accelerated mode.
# libva-mesa-driver/mesa-vdpau-drivers provide AMD decode backends.
# intel-media-driver/libva-intel-driver cover newer + older Intel iGPUs.
# nvidia-vaapi-driver enables VA-API translation on supported NVIDIA systems.
dnf5 install -y --skip-unavailable \
    linux-firmware \
    libva-utils \
    mesa-va-drivers \
    mesa-vdpau-drivers \
    radeontop
dnf5 install -y libclc

# Brave Browser — replaces Firefox
dnf5 remove -y firefox || true
dnf5 config-manager addrepo --overwrite --from-repofile=https://brave-browser-rpm-release.s3.brave.com/brave-browser.repo
dnf5 install -y brave-browser
sed -i "s/enabled=.*/enabled=0/g" /etc/yum.repos.d/brave-browser.repo
# Set Brave as the default browser for all users
update-alternatives --set x-www-browser /usr/bin/brave-browser || true
xdg-settings set default-web-browser brave-browser.desktop || true

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

# Install Claude Code VS Code extension into the system extensions directory
# so it is available to all users without a per-user install.
code --no-sandbox --user-data-dir=/tmp/vscode-install \
    --extensions-dir /usr/share/code/extensions \
    --install-extension anthropic.claude-code

# ── NVIDIA driver support ─────────────────────────────────────────────────────
# akmod-nvidia and build tools are installed in the image so that the kyth-helper
# app can compile the NVIDIA kernel module on user request without needing network
# access to fetch packages at install time.
# kernel-cachyos-devel is installed earlier while the CachyOS COPR is still
# enabled so the matching headers are available in CI/container builds.
dnf5 install -y \
    akmods \
    akmod-nvidia

# ── Kyth Helper app ───────────────────────────────────────────────────────────
# PyQt6 helper + branch switcher.  Autostarts on first login via skel.
dnf5 install -y python3-pyqt6

# Plymouth deps (theme install is in branding.sh)
dnf5 install -y plymouth plymouth-plugin-script

# ── Distrobox ─────────────────────────────────────────────────────────────────
# Lets users run mutable containers (any distro) alongside the immutable base OS.
# Essential on atomic systems for one-off package installs without rpm-ostree.
dnf5 install -y distrobox

# ── Display / resolution auto-detection ──────────────────────────────────────
# spice-vdagent: in QEMU/KVM VMs this daemon handles dynamic resolution changes
# via the SPICE protocol, so the VM display auto-resizes to the window size.
# On bare metal it is a no-op.  kscreen-doctor (from kscreen) is the KDE CLI
# for querying and configuring outputs; used by the first-login script below.
dnf5 install -y spice-vdagent kscreen
# spice-vdagentd is socket/udev-activated — no systemctl enable needed.

# Homebrew RPM deps
# Clean cached packages before this install: libxcrypt-compat has been showing
# corrupt RPM files in the persistent DNF cache. Remove once mirror stabilises.
dnf5 clean packages
dnf5 install -y --nogpgcheck gcc glibc-devel libxcrypt-compat patch ruby
