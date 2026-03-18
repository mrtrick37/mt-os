#!/bin/bash


set -euo pipefail





### Install Docker for container operations
dnf5 install -y docker || true

# Add rpmfusion free and nonfree repositories for Fedora 43
dnf5 install -y https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-43.noarch.rpm || true
dnf5 install -y https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-43.noarch.rpm || true

# Always upgrade all packages (except kernel/gamescope) before graphics/mesa installs
dnf5 upgrade -y --exclude='kernel*' --exclude='gamescope*'

# Mesa-git upgrade is handled in a separate image layer (build_files/scripts/mesa-git.sh)
# so daily mesa updates only re-download that small layer, not this entire layer.

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
    kernel-cachyos-core

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
        sysprof \
        incus \
        incus-agent \
        lxc \
        tiptop \
        trace-cmd \
        util-linux-script \
        virt-manager \
        virt-viewer \
        gnome-boxes \
        ydotool \
        tmux \
        gh

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
# Pinned to a specific release tag for reproducibility; update WINETRICKS_VER to upgrade.
# /usr/local symlinks to /var/usrlocal — ensure the target dir exists
WINETRICKS_VER="20260125"
mkdir -p /usr/local/bin
curl -fsSL "https://raw.githubusercontent.com/Winetricks/winetricks/${WINETRICKS_VER}/src/winetricks" \
    -o /usr/local/bin/winetricks
# Sanity-check: must be a shell script
head -1 /usr/local/bin/winetricks | grep -q '^#!' || { echo "winetricks download looks invalid"; exit 1; }
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
# amdgpu is in the CachyOS kernel; RADV (Vulkan) comes from mesa (Fedora repos).
# linux-firmware provides the GPU firmware blobs that amdgpu loads at runtime —
# without them the driver falls back to basic/non-accelerated mode.
# libva-mesa-driver provides the AMD VA-API backend for hardware video decode.
dnf5 install -y linux-firmware libva-utils mesa-va-drivers radeontop
dnf5 upgrade -y libdrm


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
# TODO: COPR repo bieszczaders/scx-scheds is unavailable; re-enable when it is.
# Track at: https://github.com/mrtrick37/kyth/issues/50
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

# Steam: override the system .desktop file to remove PrefersNonDefaultGPU and
# X-KDE-RunOnDiscreteGpu. On multi-GPU systems KDE uses these to launch Steam
# via DRI_PRIME, which causes steamwebhelper to SEGV on startup. Placing the
# override in /usr/local/share/applications/ takes XDG priority over
# /usr/share/applications/ and won't be clobbered by steam package updates.
mkdir -p /usr/local/share/applications
sed '/^PrefersNonDefaultGPU=\|^X-KDE-RunOnDiscreteGpu=/d' \
    /usr/share/applications/steam.desktop \
    > /usr/local/share/applications/steam.desktop

# GE-Proton is installed in a separate image layer (build_files/scripts/ge-proton.sh)
# so version bumps only re-download that layer, not this entire layer.

systemctl enable libvirtd.socket

# ── Display / resolution auto-detection ──────────────────────────────────────
# spice-vdagent: in QEMU/KVM VMs this daemon handles dynamic resolution changes
# via the SPICE protocol, so the VM display auto-resizes to the window size.
# On bare metal it is a no-op.  kscreen-doctor (from kscreen) is the KDE CLI
# for querying and configuring outputs; used by the first-login script below.
dnf5 install -y spice-vdagent kscreen
# spice-vdagentd is socket/udev-activated — no systemctl enable needed.

# First-login autostart: run kscreen-doctor to set all outputs to their
# preferred (auto) mode.  Works for both hardware and VMs.  Removes itself
# so it only fires once per user.
mkdir -p /etc/skel/.config/autostart
cat > /etc/skel/.config/autostart/kyth-set-resolution.desktop <<'RESEOF'
[Desktop Entry]
Type=Application
Name=Kyth: Set display resolution
Exec=/usr/local/bin/kyth-set-resolution
X-KDE-autostart-after=panel
Hidden=false
NoDisplay=true
RESEOF

cat > /usr/local/bin/kyth-set-resolution <<'SCRIPTEOF'
#!/usr/bin/env python3
# Set every connected output to its preferred (first-listed) mode.
# kscreen-doctor -o output format:
#   Output: 1 Virtual-1 enabled connected
#     Modes: 1:1920x1080@60  2:1280x720@60  ...
# Runs once on first login per user, then removes itself.

import os, re, subprocess, time

# Give KDE's display stack time to fully initialize before querying
time.sleep(3)

result = subprocess.run(['kscreen-doctor', '-o'], capture_output=True, text=True)

current_output = None
for line in result.stdout.splitlines():
    line = line.strip()
    # Match "Output: 1 Virtual-1 enabled connected" — name is the second word
    m = re.match(r'^Output:\s+\d+\s+(\S+)', line)
    if m:
        current_output = m.group(1)
        continue
    # Match "Modes: 1:1920x1080@60  2:..." — first mode is the preferred resolution
    if current_output and re.match(r'^Modes:', line):
        modes = re.findall(r'\d+:(\d+x\d+@[\d.]+)', line)
        if modes:
            subprocess.run([
                'kscreen-doctor',
                f'output.{current_output}.enable',
                f'output.{current_output}.mode.{modes[0]}',
            ], check=False)
        current_output = None

autostart = os.path.expanduser('~/.config/autostart/kyth-set-resolution.desktop')
try:
    os.unlink(autostart)
except OSError:
    pass
SCRIPTEOF
chmod +x /usr/local/bin/kyth-set-resolution

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
HOME_URL="https://github.com/mrtrick37/kyth"
SUPPORT_URL="https://github.com/mrtrick37/kyth/discussions"
BUG_REPORT_URL="https://github.com/mrtrick37/kyth/issues"
EOF

# ── Default KDE theme for all new users via /etc/skel ─────────────────────────
mkdir -p /etc/skel/.config
cat > /etc/skel/.config/kdeglobals <<'KDEEOF'
[General]
ColorScheme=BreezeDark

[KDE]
LookAndFeelPackage=org.kde.breezedark.desktop
KDEEOF

cat > /etc/skel/.config/plasmarc <<'PLASMAEOF'
[Theme]
name=breeze-dark
PLASMAEOF

# ── Kyth wallpaper package ────────────────────────────────────────────────────
# Install as a proper KDE wallpaper package so the L&F lookup 'Image=kyth' works.
mkdir -p /usr/share/wallpapers/kyth/contents/images
cp /ctx/wallpaper/kyth-wallpaper.svg \
    /usr/share/wallpapers/kyth/contents/images/1920x1080.svg
printf '{"KPlugin":{"Authors":[{"Name":"Kyth"}],"Id":"kyth","Name":"Kyth","License":"CC-BY-SA-4.0"},"KPackageStructure":"Wallpaper/Images"}\n' \
    > /usr/share/wallpapers/kyth/metadata.json

# Patch Breeze Dark L&F defaults to use Kyth wallpaper instead of the stock
# 'Next' wallpaper, so applying the theme never overrides the Kyth background.
BREEZE_DARK_DEFAULTS="/usr/share/plasma/look-and-feel/org.kde.breezedark.desktop/contents/defaults"
if [ -f "$BREEZE_DARK_DEFAULTS" ]; then
    sed -i 's/^Image=.*/Image=kyth/' "$BREEZE_DARK_DEFAULTS"
    grep -q '^Image=' "$BREEZE_DARK_DEFAULTS" \
        || printf '\n[Wallpaper]\nImage=kyth\n' >> "$BREEZE_DARK_DEFAULTS"
fi || true

# ── Kyth logo as system icon ──────────────────────────────────────────────────
# KDE Plasma 6 Kickoff looks up icons in this order:
#   start-here-kde-plasma → start-here-kde → start-here
# Install under all three names in hicolor (universal fallback), breeze
# (default KDE theme), and breeze-dark so every combination is covered.
for theme_dir in \
    /usr/share/icons/hicolor/scalable/apps \
    /usr/share/icons/breeze/apps/scalable \
    /usr/share/icons/breeze-dark/apps/scalable; do
    mkdir -p "${theme_dir}"
    cp /ctx/calamares/branding/kyth/kyth-logo.svg "${theme_dir}/kyth.svg"
    cp /ctx/calamares/branding/kyth/kyth-logo.svg "${theme_dir}/start-here.svg"
    cp /ctx/calamares/branding/kyth/kyth-logo.svg "${theme_dir}/start-here-kde.svg"
    cp /ctx/calamares/branding/kyth/kyth-logo.svg "${theme_dir}/start-here-kde-plasma.svg"
done
gtk-update-icon-cache -f /usr/share/icons/hicolor/    2>/dev/null || true
gtk-update-icon-cache -f /usr/share/icons/breeze/      2>/dev/null || true
gtk-update-icon-cache -f /usr/share/icons/breeze-dark/ 2>/dev/null || true

# ── First-login script: set Kickoff launcher icon to Kyth logo ────────────────
# Belt-and-suspenders: the icon theme install above should be enough, but this
# also writes the icon key directly into each user's Kickoff applet config in
# case the theme lookup is overridden by a previously cached value.
mkdir -p /usr/local/bin
cat > /usr/local/bin/kyth-set-kickoff-icon <<'KICKOFEOF'
#!/usr/bin/env python3
import os, re, subprocess

aprc = os.path.expanduser("~/.config/plasma-org.kde.plasma.desktop-appletsrc")
autostart = os.path.expanduser("~/.config/autostart/kyth-set-kickoff-icon.desktop")

if os.path.exists(aprc):
    content = open(aprc).read()
    for m in re.finditer(
        r'^\[Containments\]\[(\d+)\]\[Applets\]\[(\d+)\]',
        content, re.MULTILINE
    ):
        cont, applet = m.group(1), m.group(2)
        body_start = m.end()
        nxt = re.search(r'^\[', content[body_start:], re.MULTILINE)
        body = content[body_start: body_start + nxt.start()] if nxt else content[body_start:]
        if 'plugin=org.kde.plasma.kickoff' in body:
            subprocess.run([
                'kwriteconfig6', '--file', aprc,
                '--group', 'Containments', '--group', cont,
                '--group', 'Applets', '--group', applet,
                '--group', 'Configuration', '--group', 'General',
                '--key', 'icon', 'start-here-kde-plasma',
            ], check=False)

try:
    os.unlink(autostart)
except OSError:
    pass
KICKOFEOF
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

cat > /etc/skel/.config/plasma-org.kde.plasma.desktop-appletsrc <<'PLASMADESKTOPEOF'
[Containments][1]
wallpaperplugin=org.kde.image

[Containments][1][Wallpaper][org.kde.image][General]
Image=/usr/share/wallpapers/kyth/contents/images/1920x1080.svg
PLASMADESKTOPEOF

# ── Outlook PWA ───────────────────────────────────────────────────────────────
# Adds Microsoft Outlook to the Internet section of the app launcher via a
# .desktop file that opens it as a Brave PWA (no browser chrome).
mkdir -p /usr/share/applications
cat > /usr/share/applications/outlook-pwa.desktop <<'OUTLOOKEOF'
[Desktop Entry]
Version=1.0
Name=Outlook
Comment=Microsoft Outlook — email and calendar
Exec=brave-browser --app=https://outlook.live.com/mail/ %U
Icon=outlook-pwa
Terminal=false
Type=Application
Categories=Network;Email;
StartupWMClass=outlook.live.com__mail_
StartupNotify=true
OUTLOOKEOF
mkdir -p /usr/share/icons/hicolor/192x192/apps
cp /ctx/icons/outlook-pwa.png /usr/share/icons/hicolor/192x192/apps/outlook-pwa.png
gtk-update-icon-cache -f /usr/share/icons/hicolor/ 2>/dev/null || true

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

# ── Plymouth boot splash ───────────────────────────────────────────────────────
# Install the Kyth Plymouth theme and rebuild the initramfs so the splash is
# included.  librsvg2-tools provides rsvg-convert to render the logo SVG → PNG.
# plymouth-plugin-script provides the script module used by kyth.plymouth.
dnf5 install -y plymouth plymouth-plugin-script librsvg2-tools

PLYMOUTH_DIR=/usr/share/plymouth/themes/kyth
mkdir -p "${PLYMOUTH_DIR}"
cp /ctx/plymouth/kyth.plymouth "${PLYMOUTH_DIR}/kyth.plymouth"
cp /ctx/plymouth/kyth.script   "${PLYMOUTH_DIR}/kyth.script"

# Render logo SVG → PNG for Plymouth (Plymouth cannot read SVG natively)
rsvg-convert -w 200 \
    /ctx/calamares/branding/kyth/kyth-logo.svg \
    -o "${PLYMOUTH_DIR}/kyth-logo.png"

# Generate 16 arc-spinner frames (arc-00.png … arc-15.png).
# Each frame is a 44×44 PNG: dim track circle + 250° colored arc at a
# different rotation — the Plymouth script cycles through them to produce
# the same spinning-arc look as the Calamares installer spinner.
python3 << 'ARCEOF'
import math, os, subprocess

PLYMOUTH_DIR = "/usr/share/plymouth/themes/kyth"
N     = 16
SIZE  = 44
CX    = CY = 22
R     = 18
SWEEP = 250   # degrees — matches the Calamares arc sweep

for i in range(N):
    start_deg = i * (360.0 / N) - 90.0   # rotate so frame 0 starts at top
    end_deg   = start_deg + SWEEP

    def pt(deg):
        rad = math.radians(deg)
        return CX + R * math.cos(rad), CY + R * math.sin(rad)

    sx, sy = pt(start_deg)
    ex, ey = pt(end_deg)

    svg = f"""<svg xmlns="http://www.w3.org/2000/svg" width="{SIZE}" height="{SIZE}">
  <circle cx="{CX}" cy="{CY}" r="{R}" fill="none" stroke="#1e1e2e" stroke-width="3.5"/>
  <path d="M {sx:.4f} {sy:.4f} A {R} {R} 0 1 1 {ex:.4f} {ey:.4f}"
        fill="none" stroke="#7aa2f7" stroke-width="3.5" stroke-linecap="round"/>
</svg>"""

    svg_path = f"{PLYMOUTH_DIR}/arc-{i:02d}.svg"
    png_path = f"{PLYMOUTH_DIR}/arc-{i:02d}.png"
    with open(svg_path, "w") as f:
        f.write(svg)
    subprocess.run(["rsvg-convert", "-w", str(SIZE), "-h", str(SIZE), svg_path, "-o", png_path], check=True)
    os.unlink(svg_path)
ARCEOF

plymouth-set-default-theme kyth

# librsvg2-tools was only needed for rsvg-convert above — remove it now
# to keep the final image lean.
dnf5 remove -y librsvg2-tools && dnf5 autoremove -y || true

# Rebuild the initramfs to include Plymouth + the Kyth theme.
# TMPDIR=/var/tmp avoids EXDEV cross-device rename errors.
CACHYOS_KVER=$(ls /usr/lib/modules/ | grep cachyos | head -1)
TMPDIR=/var/tmp dracut \
    --no-hostonly \
    --add "plymouth" \
    --kver "${CACHYOS_KVER}" \
    --force \
    "/usr/lib/modules/${CACHYOS_KVER}/initramfs" \
    2> >(grep -Ev 'xattr|fail to copy' >&2)
echo "Initramfs rebuilt with Plymouth (theme: kyth)"

# ── Automatic updates: use bootc, not rpm-ostree ──────────────────────────────
# rpm-ostreed-automatic conflicts with bootc over the sysroot lock.
# Disable it entirely — bootc-fetch-apply-updates.timer is also disabled because
# its default behaviour (bootc upgrade --apply) reboots the system automatically
# whenever a new image is available, causing unexpected reboots ~1h after boot.
# Users should update manually: sudo bootc upgrade && sudo systemctl reboot
systemctl disable rpm-ostreed-automatic.timer rpm-ostreed-automatic.service 2>/dev/null || true
systemctl disable bootc-fetch-apply-updates.timer bootc-fetch-apply-updates.service 2>/dev/null || true

# useradd only reads /etc/group, but Fedora system groups live in /usr/lib/group.
# Copy any missing groups into /etc/group; create with groupadd if absent entirely.
for grp in users video audio gamemode docker; do
    if ! grep -q "^${grp}:" /etc/group; then
        if getent group "$grp" > /dev/null 2>&1; then
            getent group "$grp" >> /etc/group
        else
            groupadd "$grp"
        fi
    fi
done

# Create default user
useradd -m -G wheel,users,video,audio,gamemode,docker -s /bin/bash kyth
echo 'kyth:kyth' | chpasswd
echo '%wheel ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/wheel-nopasswd

# Hide the kyth system user from the SDDM login screen.
# Users should only see their own account (created during installation).
mkdir -p /etc/sddm.conf.d
cat > /etc/sddm.conf.d/20-hide-users.conf <<'EOF'
[Users]
HideUsers=kyth
EOF

# Purge dnf package cache — not needed at runtime and adds ~200 MB to the image.
dnf5 clean all
