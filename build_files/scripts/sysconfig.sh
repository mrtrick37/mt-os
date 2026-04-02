#!/bin/bash

set -euo pipefail

# ── Kernel sysctl parameters ──────────────────────────────────────────────────
mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/99-kyth.conf <<'SYSCTLEOF'
# Memory — reduce swap aggression and background compaction stutter
vm.swappiness = 10
vm.compaction_proactiveness = 0
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
vm.page_lock_unfairness = 1
# Disable swap read-ahead — on SSDs random I/O is fast; prefetching neighbours
# wastes bandwidth and causes micro-stutter under memory pressure
vm.page-cluster = 0
# Disable watermark boost — prevents burst memory reclaim spikes that cause stutter
vm.watermark_boost_factor = 0
# Reduce VFS cache reclaim aggressiveness — keeps game asset dentries/inodes
# in cache longer (default 100; 50 = half as eager to evict)
vm.vfs_cache_pressure = 50
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

# inotify — raise watch/instance limits for game clients and Electron launchers
# (EA App, Battle.net, etc. watch large directory trees and hit the 8192 default)
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 1024

# Disable NMI watchdog — reduces interrupt overhead on gaming desktops
kernel.nmi_watchdog = 0

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
mkdir -p /etc/tmpfiles.d
cat > /etc/tmpfiles.d/kyth-thp.conf <<'THPEOF'
w! /sys/kernel/mm/transparent_hugepage/enabled - - - - madvise
w! /sys/kernel/mm/transparent_hugepage/defrag  - - - - defer+madvise
THPEOF

# ── NVIDIA kernel module options ─────────────────────────────────────────────
# nvidia-drm.modeset=1  — required for Wayland/SDDM to use the NVIDIA KMS driver
#   instead of falling back to fbdev; without it KDE Plasma on Wayland will not
#   start on NVIDIA hardware.
# NVreg_PreserveVideoMemoryAllocations=1 — keeps VRAM contents across suspend/
#   resume cycles, preventing a black screen after wake on NVIDIA systems.
# nouveau is blacklisted: it conflicts with the proprietary driver and must not
#   load.  On AMD/Intel systems nouveau is never triggered anyway (no NVIDIA
#   hardware), so the blacklist is harmless.
cat > /etc/modprobe.d/nvidia-kyth.conf <<'NVEOF'
options nvidia-drm modeset=1
options nvidia NVreg_PreserveVideoMemoryAllocations=1
blacklist nouveau
options nouveau modeset=0
NVEOF

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

# ── WiFi — disable power management ──────────────────────────────────────────
# Linux WiFi power-save throttles the radio when idle, reducing signal
# sensitivity and causing apparent "weak signal" even close to the AP.
# NetworkManager powersave=2 disables it at the connection level (all adapters).
mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/wifi-powersave-off.conf <<'NMEOF'
[connection]
wifi.powersave = 2
NMEOF

# ── WiFi driver tweaks ────────────────────────────────────────────────────────
mkdir -p /etc/modprobe.d

# MT7921 PCIe (MediaTek Filogic 330): disable Active State Power Management.
# ASPM puts the PCIe device into a low-power state it may not reliably wake
# from, causing sudden disconnects and requiring a driver reload or reboot.
cat > /etc/modprobe.d/mt7921-kyth.conf <<'MT76EOF'
options mt7921e disable_aspm=1
MT76EOF

# iwlwifi (Intel WiFi): disable driver power-save and BT coexistence.
# bt_coex_active=0 stops the driver from halving WiFi throughput when Bluetooth
# is active (common cause of dropped signal during BT headset/controller use).
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
# NVMe: bypass scheduler entirely (DEVTYPE==disk excludes partition nodes which lack queue/scheduler)
ACTION=="add|change", KERNEL=="nvme[0-9]*", DEVTYPE=="disk", ATTR{queue/scheduler}="none"
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
# mesa_glthread=true:
#   Offloads OpenGL command submission to a second thread, improving CPU-bound
#   framerate in OpenGL games (Minecraft, older Source titles, etc.). Safe
#   system-wide; Vulkan/DXVK games are unaffected.
mkdir -p /etc/environment.d
cat > /etc/environment.d/proton-radv.conf <<'PROTONEOF'
PROTON_FORCE_LARGE_ADDRESS_AWARE=1
WINE_LARGE_ADDRESS_AWARE=1
AMD_VULKAN_ICD=RADV
PROTON_USE_NTSYNC=1
VKD3D_CONFIG=dxr
mesa_glthread=true
PROTONEOF

# ── NVIDIA NVAPI: detect at login, not at build time ─────────────────────────
# PROTON_ENABLE_NVAPI tells Proton to emulate NVIDIA's API layer.  It is only
# meaningful on systems with NVIDIA hardware; setting it on AMD/Intel causes
# games that check for NVAPI to try NVIDIA-specific paths and silently fail.
# A systemd user-environment generator runs at each login and outputs the
# variable only when an NVIDIA GPU is detected via lspci.
install -m 0755 /dev/stdin /usr/lib/systemd/user-environment-generators/80-kyth-nvapi.sh <<'NVAPIEOF'
#!/bin/bash
if lspci -d ::0300 2>/dev/null | grep -qi nvidia || \
   lspci -d ::0302 2>/dev/null | grep -qi nvidia; then
    echo "PROTON_ENABLE_NVAPI=1"
fi
NVAPIEOF

# ── Open file descriptor limit (esync / general compatibility) ────────────────
# esync requires a high open-file limit; even with NTSYNC some games fall back
# to it. 1048576 matches Bazzite and CachyOS defaults. Applied to both system
# services and user sessions.
mkdir -p /etc/systemd/system.conf.d /etc/systemd/user.conf.d
echo '[Manager]
DefaultLimitNOFILE=1048576' > /etc/systemd/system.conf.d/99-kyth-limits.conf
echo '[Manager]
DefaultLimitNOFILE=1048576' > /etc/systemd/user.conf.d/99-kyth-limits.conf

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

# systemd-remount-fs tries to remount the root filesystem, which is immutable
# on bootc/ostree systems and always fails with exit status 32. Mask it.
systemctl mask systemd-remount-fs.service

systemctl enable rtkit-daemon.service 2>/dev/null || true
systemctl enable input-remapper.service 2>/dev/null || true
# Fedora/libvirt can expose either legacy libvirtd or modular virtqemud units.
# Enable whichever socket exists so image builds stay portable across releases.
if systemctl list-unit-files --type=socket --no-legend 2>/dev/null | grep -q '^libvirtd\.socket'; then
    systemctl enable libvirtd.socket 2>/dev/null || true
elif systemctl list-unit-files --type=socket --no-legend 2>/dev/null | grep -q '^virtqemud\.socket'; then
    systemctl enable virtqemud.socket 2>/dev/null || true
else
    echo "libvirt socket unit not found; skipping enable."
fi
systemctl enable docker.socket 2>/dev/null || true
systemctl enable fwupd 2>/dev/null || true

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
for grp in users video audio gamemode docker disk kvm tty clock kmem input render lp utmp plugdev; do
    if ! grep -q "^${grp}:" /etc/group; then
        if getent group "$grp" > /dev/null 2>&1; then
            getent group "$grp" >> /etc/group
        else
            groupadd "$grp"
        fi
    fi
done
