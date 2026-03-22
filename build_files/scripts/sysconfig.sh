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

systemctl enable input-remapper.service 2>/dev/null || true
systemctl enable libvirtd.socket
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
for grp in users video audio gamemode docker; do
    if ! grep -q "^${grp}:" /etc/group; then
        if getent group "$grp" > /dev/null 2>&1; then
            getent group "$grp" >> /etc/group
        else
            groupadd "$grp"
        fi
    fi
done
