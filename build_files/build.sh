#!/bin/bash


set -ouex pipefail





### Install Docker for container operations
dnf5 install -y docker || true

# Automated cleanup: keep only the latest build image
LATEST_IMAGE="kyth-base:stable"

# Remove all stopped containers
docker container prune -f 2>/dev/null || true

# Remove all images except the latest build
for img in $(docker images --format '{{.Repository}}:{{.Tag}}' | grep -v "$LATEST_IMAGE"); do
    docker rmi "$img" 2>/dev/null || true
done

# Remove all unused volumes
docker volume prune -f 2>/dev/null || true

# Remove all unused networks
docker network prune -f 2>/dev/null || true

# Remove build cache
docker system prune -af 2>/dev/null || true

# Add rpmfusion free and nonfree repositories for Fedora 43 and 44
dnf5 install -y https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-43.noarch.rpm || true
dnf5 install -y https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-43.noarch.rpm || true
dnf5 install -y https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-44.noarch.rpm || true
dnf5 install -y https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-44.noarch.rpm || true

# Always upgrade all packages (except kernel/gamescope) before graphics/mesa installs
dnf5 upgrade -y --exclude='kernel*' --exclude='gamescope*'

# Ensure latest mesa and graphics drivers
dnf5 upgrade -y mesa* mesa-dri-drivers mesa-vulkan-drivers mesa-libGL mesa-libGLU mesa-libEGL mesa-libgbm mesa-libxatracker mesa-libOpenCL || true
dnf5 upgrade -y xorg-x11-drv-amdgpu xorg-x11-drv-nouveau xorg-x11-drv-intel xorg-x11-drv-vesa xorg-x11-drv-vmware xorg-x11-drv-qxl xorg-x11-drv-nvidia || true

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
        cp --no-preserve=all "/boot/vmlinuz-${CACHYOS_KVER}" "/usr/lib/modules/${CACHYOS_KVER}/vmlinuz" 2>/dev/null
    fi
fi

# Write dracut config before generating initramfs.
# Force the ostree dracut module — required for bootc/ostree deployments.
# Without this the initramfs cannot find or mount the root filesystem.
# dracut skips it during container builds because there is no live ostree
# deployment to auto-detect.
mkdir -p /etc/dracut.conf.d
cat > /etc/dracut.conf.d/99-kyth.conf <<'DRACUTEOF'
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

    # Ensure osbuild-selinux is installed before usage
    if ! rpm -q osbuild-selinux >/dev/null 2>&1; then
        echo "Installing osbuild-selinux..."
        dnf5 install -y osbuild-selinux || {
            echo "Failed to install osbuild-selinux. Exiting." >&2
            exit 1
        }
    fi

    # Install all required packages
    dnf5 install -y \
        p7zip \
        p7zip-plugins \
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

## Removed ananicy-cpp service enablement per user request

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

### GPU drivers


# ── AMD ───────────────────────────────────────────────────────────────────────
# amdgpu is in the CachyOS kernel; radv (Vulkan) is now from mesa-git above.
# Add VA-API/VDPAU for hardware video decode and radeontop for monitoring.
dnf5 install -y libva-utils radeontop


# ── Kernel sysctl parameters ──────────────────────────────────────────────────
mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/99-kyth.conf <<'SYSCTLEOF'
# Memory — reduce swap aggression and background compaction stutter
vm.swappiness = 10
vm.compaction_proactiveness = 0
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
vm.page_lock_unfairness = 1

# Network — activate BBRv3 (built into CachyOS kernel)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Network socket buffers — raise caps for high-throughput workloads and gaming
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
# TCP Fast Open — reduce connection latency for repeat destinations
net.ipv4.tcp_fastopen = 3

# Scheduler
kernel.sched_autogroup_enabled = 1

# Disable split-lock mitigation — some older/ported games use split-lock ops
kernel.split_lock_mitigate = 0
SYSCTLEOF

# Load tcp_bbr module at boot so the BBRv3 sysctl takes effect
echo 'tcp_bbr' > /etc/modules-load.d/bbr.conf

# ── Transparent Huge Pages → madvise ─────────────────────────────────────────
# 'always' (kernel default) forces THP on all allocations and causes stutter.
# 'madvise' lets apps that benefit (e.g. JVMs, some game engines) opt in.
dnf5 install -y libclc
mkdir -p /etc/tmpfiles.d
cat > /etc/tmpfiles.d/kyth-thp.conf <<'THPEOF'
w! /sys/kernel/mm/transparent_hugepage/enabled - - - - madvise
w! /sys/kernel/mm/transparent_hugepage/defrag  - - - - defer+madvise
THPEOF

# ── NTSYNC ────────────────────────────────────────────────────────────────────
# CachyOS kernel ships the ntsync module. The udev rule gives the 'users' group
# access to /dev/ntsync so Wine/Proton can use NT synchronization primitives
# (faster and lower-latency than esync/fsync for Windows game compatibility).
echo 'KERNEL=="ntsync", GROUP="users", MODE="0660"' \
    > /usr/lib/udev/rules.d/99-ntsync.rules

# Capped at 8 GB so zram doesn't eat all RAM on large-memory systems.
cat > /etc/systemd/zram-generator.conf <<'ZRAMEOF'
[zram0]
zram-size = min(ram / 2, 8192)
compression-algorithm = zstd
ZRAMEOF

# ── gamemode configuration ────────────────────────────────────────────────────
# Applied when a game calls gamemoderun or uses the gamemode SDL hook.
# renice/ioprio: game process gets higher CPU + I/O scheduling priority.
# gpu: switches AMD GPU to high-performance power profile during gameplay.
cat > /etc/gamemode.ini <<'GAMEMODEEOF'
[general]
renice = 10
ioprio = 0

[cpu]
park_cores = no
pin_cores = yes

[gpu]
apply_gpu_optimisations = accept-responsibility
amd_performance_level = high
GAMEMODEEOF


# ── scx userspace schedulers ──────────────────────────────────────────────────
# sched-ext (scx) is a BPF-based scheduler framework in the CachyOS kernel.
# scx_lavd is optimised for interactive + gaming — it prioritises latency-
# sensitive threads (audio, input, render) while keeping throughputs tasks warm.
# (COPR repo bieszczaders/scx-scheds is unavailable; skipping scx-scheds install.)
## If/when scx-scheds becomes available, re-enable the following:
# dnf5 copr enable -y bieszczaders/scx-scheds
# dnf5 install -y --skip-unavailable scx-scheds
# dnf5 copr disable -y bieszczaders/scx-scheds

# Configure scxd to use lavd by default, then enable the service
# mkdir -p /etc/scx
# cat > /etc/scx/config <<'SCXEOF'
# SCX_SCHEDULER=scx_lavd
# SCX_FLAGS=--auto-mode
# SCXEOF
# systemctl enable scxd.service 2>/dev/null || true

# ── WiFi — disable power management ──────────────────────────────────────────
# Linux WiFi power-save throttles the radio when idle, reducing signal
# sensitivity and causing apparent "weak signal" even close to the AP.
# NetworkManager powersave=2 disables it at the connection level (all adapters).
mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/wifi-powersave-off.conf <<'NMEOF'
[connection]
wifi.powersave = 2
NMEOF

# iwlwifi (Intel WiFi) specific: disable driver power-save and BT coexistence.
# bt_coex_active=0 stops the driver from halving WiFi throughput when Bluetooth
# is active (common cause of dropped signal during BT headset/controller use).
mkdir -p /etc/modprobe.d
cat > /etc/modprobe.d/iwlwifi-kyth.conf <<'IWLEOF'
options iwlwifi power_save=0 bt_coex_active=0
IWLEOF

# ── I/O schedulers ────────────────────────────────────────────────────────────
# 'none' on NVMe — the drive's own internal queues are better than any kernel
#   scheduler overhead; multi-queue hardware makes mq-deadline redundant.
# 'mq-deadline' on SATA SSD — adds deadline fairness with minimal latency.
# 'bfq' on rotational — budget fair queuing prevents seek storms.
mkdir -p /etc/udev/rules.d
cat > /etc/udev/rules.d/60-ioschedulers.rules <<'IOEOF'
# NVMe: bypass scheduler entirely
ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/scheduler}="none"
# SATA/NVMe-HDD SSDs (non-rotational, non-nvme): deadline with low latency
ACTION=="add|change", KERNEL=="sd[a-z]*", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"
# HDDs: BFQ to avoid seek storms
ACTION=="add|change", KERNEL=="sd[a-z]*", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
IOEOF

# ── PipeWire low-latency audio ─────────────────────────────────────────────────
# Default quantum 1024 (~21 ms at 48 kHz) is a reasonable starting point for
# gaming — low enough to avoid audio lag, high enough to avoid xruns.
# Apps that need <1 ms (e.g. JACK DAW) can request smaller buffers directly.
mkdir -p /etc/pipewire/pipewire.conf.d
cat > /etc/pipewire/pipewire.conf.d/99-kyth.conf <<'PWEOF'
context.properties = {
    default.clock.rate          = 48000
    default.clock.quantum       = 1024
    default.clock.min-quantum   = 32
    default.clock.max-quantum   = 8192
}
PWEOF

# ── Proton / RADV environment variables ───────────────────────────────────────
# PROTON_FORCE_LARGE_ADDRESS_AWARE / WINE_LARGE_ADDRESS_AWARE:
#   Forces 32-bit Windows games to use the full 4 GB address space, reducing
#   OOM crashes in memory-heavy titles (e.g. Skyrim modded, DayZ).
# RADV_PERFTEST=gpl:
#   Enables Vulkan Graphics Pipeline Library on RADV — pre-compiles pipeline
#   shaders during load rather than at draw time, eliminating compilation stutter.
mkdir -p /etc/environment.d
cat > /etc/environment.d/proton-radv.conf <<'PROTONEOF'
PROTON_FORCE_LARGE_ADDRESS_AWARE=1
WINE_LARGE_ADDRESS_AWARE=1
RADV_PERFTEST=gpl
PROTONEOF

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

# Steam: disable CEF browser sandbox — required on bootc/ostree systems where
# user namespace restrictions prevent the Chromium sandbox from initialising,
# causing steamwebhelper to SEGV at startup.
mkdir -p /etc/environment.d
echo 'STEAM_DISABLE_BROWSER_SANDBOX=1' > /etc/environment.d/steam.conf

systemctl enable libvirtd.socket
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

# Ensure the built image advertises the Kyth product name. Some boot/installer
# menus derive their display strings from `/etc/os-release` or similar metadata.
# We overwrite or create `/etc/os-release` with Kyth values so boot menus show
# "Kyth" instead of upstream branding.
cat > /etc/os-release <<'EOF' || true
NAME="Kyth"
PRETTY_NAME="Kyth 43"
ID=fedora
VERSION="43"
VERSION_ID="43"
ANSI_COLOR="0;34"
HOME_URL="https://example.com/kyth"
SUPPORT_URL="https://example.com/kyth/support"
BUG_REPORT_URL="https://example.com/kyth/issues"
EOF

# ── Kyth Look-and-Feel package ───────────────────────────────────────────────
# Custom LnF that wraps Breeze Dark and sets a solid black wallpaper on ALL
# screens via a plasmoidsetupscripts JS file — this covers every containment
# ID regardless of how many monitors are connected.
LNF_DIR=/usr/share/plasma/look-and-feel/org.kde.kyth
mkdir -p "${LNF_DIR}/contents/plasmoidsetupscripts"

cat > "${LNF_DIR}/metadata.json" <<'METAEOF'
{
    "KPackageStructure": "Plasma/LookAndFeel",
    "KPlugin": {
        "Authors": [{"Email": "", "Name": "Kyth"}],
        "Description": "Kyth — Breeze Dark with solid black wallpaper",
        "Id": "org.kde.kyth",
        "Name": "Kyth",
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
LookAndFeelPackage=org.kde.kyth
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
cat > /usr/local/bin/kyth-set-kickoff-icon <<'KICKOFICONEOF'
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
rm -f "${HOME}/.config/autostart/kyth-set-kickoff-icon.desktop"
KICKOFICONEOF
chmod +x /usr/local/bin/kyth-set-kickoff-icon

mkdir -p /etc/skel/.config/autostart
cat > /etc/skel/.config/autostart/kyth-set-kickoff-icon.desktop <<'AUTOSTARTEOF'
[Desktop Entry]
Type=Application
Name=Kyth: Set Kickoff Icon
Exec=/usr/local/bin/kyth-set-kickoff-icon
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
# (some base images include a Waydroid helper that we don't ship in Kyth)
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
