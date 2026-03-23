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

# Always upgrade all packages (except kernel/gamescope) before graphics/mesa installs
dnf5 upgrade -y --exclude='kernel*' --exclude='gamescope*'

# Mesa-git upgrade is handled in a separate image layer (build_files/scripts/mesa-git.sh)
# so daily mesa updates only re-download that small layer, not this entire layer.

# Kernel was installed in the build_base layer. Capture the version here
# since it's needed later for the Plymouth initramfs rebuild.
CACHYOS_KVER=$(basename "$(echo /usr/lib/modules/*cachyos*)")

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

# ── topgrade ─────────────────────────────────────────────────────────────────
# Not in Fedora 43 repos — install pre-built binary from GitHub releases.
# Uses the musl-linked build for maximum compatibility across libc versions.
TOPGRADE_REPO_API="https://api.github.com/repos/topgrade-rs/topgrade/releases/latest"
TMPDIR_TG=$(mktemp -d)
release_json="${TMPDIR_TG}/release.json"
if curl -fsSL "${TOPGRADE_REPO_API}" -o "${release_json}" 2>/dev/null; then
    TOPGRADE_URL=$(
        grep -o 'https://[^"]*x86_64[^"]*linux[^"]*musl[^"]*\.tar\.gz' "${release_json}" \
        | head -n1
    ) || true
    if [[ -n "${TOPGRADE_URL}" ]]; then
        TOPGRADE_TARBALL=$(basename "${TOPGRADE_URL}")
        curl -fsSL "${TOPGRADE_URL}" -o "${TMPDIR_TG}/${TOPGRADE_TARBALL}"
        tar -xzf "${TMPDIR_TG}/${TOPGRADE_TARBALL}" -C "${TMPDIR_TG}/"
        find "${TMPDIR_TG}" -name 'topgrade' -type f \
            -exec install -m 0755 {} /usr/bin/topgrade \;
        echo "topgrade installed: $(topgrade --version 2>/dev/null || echo 'unknown version')"
    else
        echo "topgrade: no musl x86_64 tarball found in release assets; skipping."
    fi
else
    echo "topgrade: failed to fetch release info from GitHub; skipping."
fi
rm -rf "${TMPDIR_TG}"

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
systemctl enable input-remapper.service 2>/dev/null || true

# Download winetricks from upstream (package version is often outdated)
# Pin to the signed release commit so the build does not trust a mutable ref
# for an executable shell script.
# /usr/local symlinks to /var/usrlocal — ensure the target dir exists
WINETRICKS_VER="20260125"
WINETRICKS_COMMIT="b76e1ee"
mkdir -p /usr/local/bin
curl -fsSL "https://raw.githubusercontent.com/Winetricks/winetricks/${WINETRICKS_COMMIT}/src/winetricks" \
    -o /tmp/winetricks
# Sanity-check: must be a shell script before installing
head -1 /tmp/winetricks | grep -q '^#!' || { echo "winetricks download looks invalid"; exit 1; }
install -m 0755 /tmp/winetricks /usr/local/bin/winetricks
rm -f /tmp/winetricks

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
# Raise memory map limit for games with large numbers of mappings (Star Citizen, etc.)
vm.max_map_count = 2147483642

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

is_enabled() {
    case "${1,,}" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

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

# ── scx userspace schedulers ──────────────────────────────────────────────────
# sched-ext (scx) is a BPF-based scheduler framework in the CachyOS kernel.
# scx_lavd is optimised for interactive + gaming — it prioritises latency-
# sensitive threads (audio, input, render) while keeping throughput tasks warm.
#
# We pull pre-built binaries directly from the upstream GitHub release rather
# than relying on a COPR that may not have a Fedora 43 build available.
if is_enabled "${ENABLE_SCX:-1}"; then
    SCX_REPO_API="https://api.github.com/repos/sched-ext/scx/releases/latest"
    TMPDIR_SCX=$(mktemp -d)

    release_json="${TMPDIR_SCX}/release.json"
    if curl -fsSL "${SCX_REPO_API}" -o "${release_json}" 2>/dev/null; then
        # Find a Linux x86_64 binary tarball in the release assets
        SCX_TARBALL_URL=$(
            grep -o 'https://[^"]*\.tar\.gz' "${release_json}" \
            | grep -i 'x86_64' \
            | grep -iv 'source' \
            | head -n1
        ) || true

        if [[ -n "${SCX_TARBALL_URL}" ]]; then
            SCX_TARBALL=$(basename "${SCX_TARBALL_URL}")
            echo "scx: downloading ${SCX_TARBALL}"
            curl -fsSL "${SCX_TARBALL_URL}" -o "${TMPDIR_SCX}/${SCX_TARBALL}"
            tar -xzf "${TMPDIR_SCX}/${SCX_TARBALL}" -C "${TMPDIR_SCX}/"

            # Install scx_* scheduler binaries and scxd
            find "${TMPDIR_SCX}" \( -name 'scx_*' -o -name 'scxd' \) -type f \
                -exec install -m 0755 {} /usr/bin/ \;

            if command -v scxd >/dev/null 2>&1; then
                # Provide scxd.service — not present without the RPM
                mkdir -p /usr/lib/systemd/system
                cat > /usr/lib/systemd/system/scxd.service <<'SCXSVCEOF'
[Unit]
Description=sched-ext userspace scheduler daemon
Documentation=https://github.com/sched-ext/scx
After=basic.target

[Service]
Type=simple
EnvironmentFile=-/etc/scx/config
ExecStart=/usr/bin/scxd
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SCXSVCEOF

                # Pick the best available scheduler: lavd > rusty > bpfland
                SCX_SCHEDULER=""
                for sched in scx_lavd scx_rusty scx_bpfland; do
                    if command -v "$sched" >/dev/null 2>&1; then
                        SCX_SCHEDULER="$sched"
                        break
                    fi
                done

                if [[ -n "$SCX_SCHEDULER" ]]; then
                    mkdir -p /etc/scx
                    cat > /etc/scx/config <<SCXEOF
SCX_SCHEDULER=${SCX_SCHEDULER}
SCX_FLAGS=--auto-mode
SCXEOF
                    systemctl enable scxd.service 2>/dev/null || true
                    echo "scx: enabled ${SCX_SCHEDULER}"
                else
                    echo "scx: no scheduler binaries found in archive"
                fi
            else
                echo "scx: scxd not found after extraction"
            fi
        else
            echo "scx: no x86_64 tarball found in release assets; skipping."
        fi
    else
        echo "scx: failed to fetch release info from GitHub; skipping."
    fi

    rm -rf "${TMPDIR_SCX}"
else
    echo "ENABLE_SCX is off; skipping scx scheduler install."
fi

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
# SATA SSDs (non-rotational): deadline with low latency
ACTION=="add|change", KERNEL=="sd[a-z]*", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"
# HDDs: BFQ to avoid seek storms
ACTION=="add|change", KERNEL=="sd[a-z]*", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
# VirtIO block (QEMU/KVM VMs): mq-deadline — BFQ can stall under heavy sequential I/O
ACTION=="add|change", KERNEL=="vd[a-z]*", ATTR{queue/scheduler}="mq-deadline"
IOEOF

# ── PipeWire low-latency audio ─────────────────────────────────────────────────
# 128 samples at 48 kHz = ~2.7 ms latency — low enough to eliminate perceptible
# audio lag in games while staying stable on typical hardware.
# min-quantum=32 lets pro-audio apps request sub-1 ms when needed.
# Apps that need higher buffering (e.g. Bluetooth) negotiate up automatically.
mkdir -p /etc/pipewire/pipewire.conf.d
cat > /etc/pipewire/pipewire.conf.d/99-kyth.conf <<'PWEOF'
context.properties = {
    default.clock.rate          = 48000
    default.clock.quantum       = 128
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
systemctl enable fwupd 2>/dev/null || true

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

# First-login autostart: run kscreen-doctor to set all outputs to their
# preferred (auto) mode.  Works for both hardware and VMs.  Removes itself
# so it only fires once per user.
mkdir -p /etc/skel/.config/autostart
cat > /etc/skel/.config/autostart/kyth-set-resolution.desktop <<'RESEOF'
[Desktop Entry]
Type=Application
Name=Kyth: Set display resolution
Exec=/usr/bin/kyth-set-resolution
X-KDE-autostart-after=panel
Hidden=false
NoDisplay=true
RESEOF

cat > /usr/bin/kyth-set-resolution <<'SCRIPTEOF'
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
chmod +x /usr/bin/kyth-set-resolution

# Homebrew — system-wide install to /home/linuxbrew (= /var/home/linuxbrew at runtime)
# Owned by a dedicated non-root 'linuxbrew' system user so topgrade does not invoke
# brew via sudo (which brew refuses). Wheel group gets write access so any wheel
# user can install/update formulae without privilege escalation.
dnf5 install -y gcc glibc-devel libxcrypt-compat patch ruby
useradd -r -d /home/linuxbrew -M -s /sbin/nologin linuxbrew
git clone https://github.com/Homebrew/brew /home/linuxbrew/.linuxbrew
chown -R linuxbrew:wheel /home/linuxbrew
chmod -R g+w /home/linuxbrew
find /home/linuxbrew -type d -exec chmod g+s {} \;
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

# ── Plasma / PowerDevil hardening ─────────────────────────────────────────────
# KDE documents POWERDEVIL_NO_DDCUTIL=1 as a supported workaround when
# PowerDevil's DDC/CI monitor integration causes instability. On Kyth's AMD
# laptop targets, repeated libddcutil/backlight activity has correlated with
# display-timeout/pageflip failures, so default to the safer path:
# keep PowerDevil running, but stop it from talking to external monitors via
# ddcutil. Tradeoff: external monitor brightness control via DDC/CI is disabled.
#
# Add a second guardrail at the libddcutil layer as well. This keeps any
# consumer that does load libddcutil from starting display-watch threads, which
# are a known source of instability on some monitor/GPU combinations.
mkdir -p /etc/xdg/plasma-workspace/env /etc/xdg/ddcutil
cat > /etc/environment.d/90-kyth-powerdevil.conf <<'POWERDEVILEOF'
POWERDEVIL_NO_DDCUTIL=1
POWERDEVILEOF
cat > /etc/xdg/plasma-workspace/env/90-kyth-powerdevil.sh <<'POWERDEVILSHEOF'
#!/bin/sh
export POWERDEVIL_NO_DDCUTIL=1
POWERDEVILSHEOF
chmod +x /etc/xdg/plasma-workspace/env/90-kyth-powerdevil.sh
cat > /etc/xdg/ddcutil/ddcutilrc <<'DDCUTILRCEOF'
[libddcutil]
options: --disable-watch-displays
DDCUTILRCEOF

# ── Kyth wallpaper package ────────────────────────────────────────────────────
# Install as a proper KDE wallpaper package so the L&F lookup 'Image=kyth' works.
mkdir -p /usr/share/wallpapers/kyth/contents/images
cp /ctx/wallpaper/kyth-wallpaper.svg \
    /usr/share/wallpapers/kyth/contents/images/1920x1080.svg
printf '{"KPlugin":{"Authors":[{"Name":"Kyth"}],"Id":"kyth","Name":"Kyth","License":"CC-BY-SA-4.0"},"KPackageStructure":"Wallpaper/Images"}\n' \
    > /usr/share/wallpapers/kyth/metadata.json

# Patch all L&F defaults (Fedora variants + Breeze) to use Kyth wallpaper.
# Fedora Kinoite ships org.fedoraproject.fedora*.desktop themes that set
# Image=Fedora; we replace that in every theme so no L&F can restore the
# stock Fedora rocket wallpaper.
find /usr/share/plasma/look-and-feel -name defaults | while read -r f; do
    sed -i 's/^Image=.*/Image=kyth/' "$f"
    grep -q '^Image=' "$f" || printf '\n[Wallpaper]\nImage=kyth\n' >> "$f"
done

# System-wide XDG fallback — applied to every user before their personal
# config exists, so first-boot always shows the Kyth wallpaper.
mkdir -p /etc/xdg
cat > /etc/xdg/plasma-org.kde.plasma.desktop-appletsrc <<'XDGPLASMAEOF'
[Containments][1][Wallpaper][org.kde.image][General]
Image=/usr/share/wallpapers/kyth/contents/images/1920x1080.svg
XDGPLASMAEOF

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
cat > /usr/bin/kyth-set-kickoff-icon <<'KICKOFEOF'
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
chmod +x /usr/bin/kyth-set-kickoff-icon

mkdir -p /etc/skel/.config/autostart
cat > /etc/skel/.config/autostart/kyth-set-kickoff-icon.desktop <<'AUTOSTARTEOF'
[Desktop Entry]
Type=Application
Name=Kyth: Set Kickoff Icon
Exec=/usr/bin/kyth-set-kickoff-icon
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

# ── MangoHud defaults ─────────────────────────────────────────────────────────
# Ship a sensible system-wide config so MangoHud shows useful info out of the box.
# Users can override in ~/.config/MangoHud/MangoHud.conf or per-app.
mkdir -p /etc/MangoHud
install -m 0644 /ctx/MangoHud.conf /etc/MangoHud/MangoHud.conf

install -m 0755 /ctx/kyth-welcome/kyth-welcome /usr/bin/kyth-welcome
install -m 0644 /ctx/kyth-welcome/kyth-welcome.desktop \
    /usr/share/applications/kyth-welcome.desktop
install -m 0755 /ctx/game-performance /usr/bin/game-performance
install -m 0755 /ctx/kyth-performance-mode /usr/bin/kyth-performance-mode
install -m 0755 /ctx/zink-run /usr/bin/zink-run
install -m 0755 /ctx/kyth-kerver /usr/bin/kyth-kerver
install -m 0755 /ctx/kyth-device-info /usr/bin/kyth-device-info
install -m 0755 /ctx/kyth-creator-check /usr/bin/kyth-creator-check
install -m 0755 /ctx/kyth-duperemove /usr/bin/kyth-duperemove
install -m 0755 /ctx/kyth-local-bin-migrate /usr/bin/kyth-local-bin-migrate
install -m 0644 /ctx/kyth-duperemove.service /usr/lib/systemd/system/kyth-duperemove.service
install -m 0644 /ctx/kyth-duperemove.timer /usr/lib/systemd/system/kyth-duperemove.timer
install -m 0644 /ctx/kyth-local-bin-migrate.service /usr/lib/systemd/system/kyth-local-bin-migrate.service
install -m 0755 /ctx/kyth-ge-proton-update /usr/bin/kyth-ge-proton-update
install -m 0644 /ctx/kyth-ge-proton-update.service /usr/lib/systemd/system/kyth-ge-proton-update.service
install -m 0644 /ctx/kyth-ge-proton-update.timer /usr/lib/systemd/system/kyth-ge-proton-update.timer
install -m 0644 /ctx/kyth-flathub-setup.service /usr/lib/systemd/system/kyth-flathub-setup.service
install -m 0440 /ctx/kyth-bootc-sudo /etc/sudoers.d/kyth-bootc

# Autostart on first login — removes itself after running once (like kyth-set-resolution).
mkdir -p /etc/skel/.config/autostart
cat > /etc/skel/.config/autostart/kyth-welcome.desktop <<'WELCOMEEOF'
[Desktop Entry]
Type=Application
Name=Kyth Helper
Exec=/usr/bin/kyth-welcome
X-KDE-autostart-after=panel
Hidden=false
NoDisplay=true
WELCOMEEOF

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

plymouth-set-default-theme kyth

# librsvg2-tools was only needed for rsvg-convert above — remove it now
# to keep the final image lean.
dnf5 remove -y librsvg2-tools && dnf5 autoremove -y || true

# Rebuild the initramfs to include Plymouth + the Kyth theme.
# TMPDIR=/var/tmp avoids EXDEV cross-device rename errors.
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

# ── ujust recipes ─────────────────────────────────────────────────────────────
# Install Kyth-specific ujust recipes so users can run e.g. "ujust rebase kyth:stable".
mkdir -p /usr/share/ublue-os/just
cp /ctx/just/kyth.just /usr/share/ublue-os/just/75-kyth.just
systemctl enable kyth-local-bin-migrate.service 2>/dev/null || true
systemctl enable kyth-duperemove.timer 2>/dev/null || true
systemctl enable kyth-ge-proton-update.timer 2>/dev/null || true
systemctl enable kyth-flathub-setup.service 2>/dev/null || true

# ── GE-Proton runtime update path ─────────────────────────────────────────────
# The weekly timer installs new GE-Proton to /var/lib/kyth/ge-proton/ (/var is
# writable on an immutable system). Tell Steam to check this path in addition to
# the build-time install in /usr/share/steam/compatibilitytools.d/.
# The directory must exist at first boot — Lutris (and Steam) call os.stat() on
# every path in STEAM_EXTRA_COMPAT_TOOLS_PATHS and crash with FileNotFoundError
# if any are missing, even before the update service has run for the first time.
mkdir -p /var/lib/kyth/ge-proton
echo 'STEAM_EXTRA_COMPAT_TOOLS_PATHS=/var/lib/kyth/ge-proton' > /etc/environment.d/ge-proton.conf

# Purge dnf package cache — not needed at runtime and adds ~200 MB to the image.
dnf5 clean all
