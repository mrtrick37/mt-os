# Kyth

An atomic gaming and development desktop built on Fedora Kinoite with the CachyOS kernel. The entire OS ships as a container image — immutable, atomic updates, one-command rollback. Installed via the Anaconda WebUI installer from a live ISO.

> Work in progress. Don't install on anything you care about.

---

## What it is

Kyth is a custom bootc image. The OS is a container image built with Docker, installed to disk via Anaconda WebUI, and updated atomically — rolling back is one command.

| | |
|---|---|
| **Base** | Fedora 43 KDE Plasma (`ublue-os/kinoite-main:43`) |
| **Kernel** | CachyOS — BORE scheduler, sched-ext, BBRv3, NTSYNC, latency-tuned |
| **GPU drivers** | Mesa-git (bleeding-edge RADV/RADEONSI from `xxmitsu/mesa-git` COPR) |
| **Display** | KDE Plasma 6 on Wayland |
| **Installer** | Anaconda WebUI — pulls OS image from the registry at install time |
| **Theme** | Breeze Dark with Kyth branding, Plymouth boot splash |
| **SELinux** | Permissive (Docker builds cannot preserve security xattrs) |

---

## What's included

### Gaming

- Steam (with first-run setup notification), Lutris, GameMode, gamescope, MangoHud, vkBasalt
- umu-launcher, winetricks (pinned upstream release), libFAudio, OpenXR
- OBS Studio + obs-vkcapture (GPU capture without display compositor overhead)
- GE-Proton — pre-installed at build time, updated weekly via systemd timer
- scx schedulers (scx_lavd / scx_rusty / scx_bpfland via scxd, auto-mode) — prioritises latency-sensitive threads during gaming
- system76-scheduler — dynamically adjusts process priorities based on focused window
- ananicy-cpp — static per-process CPU/IO priority rules
- NTSYNC udev rules (faster Wine sync primitives, lower-latency than esync/fsync)
- RADV_PERFTEST=gpl — Vulkan Graphics Pipeline Library enabled by default
- AMD GPU high-performance power profile during gameplay (GameMode)
- `game-performance` and `zink-run` helper wrappers
- Weekly `duperemove` timer for reclaiming duplicate blocks on supported filesystems
- input-remapper (remap controllers, mice, keyboards at the kernel level)
- KDE Connect

### Development

- Visual Studio Code with the Claude Code extension pre-installed system-wide
- Brave browser (replaces Firefox)
- GitHub CLI (`gh`)
- Homebrew — system-wide, wheel group owns `/home/linuxbrew`
- topgrade (latest musl release, auto-updates all package managers)
- Docker
- distrobox (run any-distro containers alongside the immutable base)
- libvirt / QEMU / incus + LXC
- NVIDIA kernel module support (akmod-nvidia pre-installed for on-demand build)

### Observability

- trace-cmd, tiptop, sysprof, radeontop

### System tuning

- **Memory:** vm.swappiness=10, THP=madvise, vm.max_map_count=2147483642 (Star Citizen etc.), vm.compaction_proactiveness=0
- **Network:** TCP BBRv3, raised socket buffers (64 MB), TCP Fast Open
- **Audio:** PipeWire at 48 kHz / 128-sample quantum (~2.7 ms latency), min-quantum=32
- **Storage:** I/O scheduler per device type — `none` on NVMe, `mq-deadline` on SATA SSD, `bfq` on HDD
- **Gaming:** split-lock mitigation disabled, kernel.sched_autogroup_enabled=1
- **Wine/Proton:** PROTON_FORCE_LARGE_ADDRESS_AWARE + WINE_LARGE_ADDRESS_AWARE (full 4 GB address space for 32-bit games)
- zram (min(RAM/2, 8 GB), zstd compression)
- WiFi power-save disabled system-wide; Intel WiFi BT coexistence disabled
- PowerDevil DDC/CI and libddcutil display-watch threads disabled (reduces AMD display instability)
- spice-vdagent for automatic display resize in QEMU/KVM VMs
- Automatic updates disabled (no surprise reboots) — update manually: `sudo bootc upgrade`

---

## Branches and image tags

| Branch | Image tag | Purpose |
|--------|-----------|---------|
| `main` | `:latest` | Stable (relatively speaking) |
| `testing` | `:testing` | Active development — may be unstable |

Both branches rebuild daily at 10:05 UTC and on every push.

Switch between them on an installed system:

```bash
sudo bootc switch ghcr.io/mrtrick37/kyth:testing
sudo bootc switch ghcr.io/mrtrick37/kyth:latest
```

---

## Install

### Download Latest Live ISO from Releases

1. Flash to USB (`dd`, Balena Etcher, Ventoy, etc.)
2. Boot — KDE Plasma autologins as `liveuser`, no password required
3. Click **Install Kyth** on the desktop
4. The Anaconda WebUI opens in Brave — configure disk, locale, timezone, and user account
5. Click **Install** — the OS image (~4 GB) is pulled from the container registry and written to disk
6. Reboot into the installed system

**Requirements:** 8 GB RAM minimum for the live session. Active network connection required (netinstall).

### Rebase from an existing Fedora atomic system

```bash
sudo bootc switch ghcr.io/mrtrick37/kyth:latest
```

---

## Updates

```bash
sudo bootc upgrade
```

Updates are atomic — the previous deployment is kept as a fallback and selectable at the GRUB menu. There is no package manager on the running system; all changes go through the image build.

For user applications use Flatpak (via Discover) or Homebrew.

---

## Build locally

**Requirements:** `docker`, `just`

```bash
# Step 1 — build the base image (CachyOS kernel + Fedora Kinoite)
just build-base

# Step 2 — build the full Kyth OS image
just build

# Step 3 — build the live ISO
just build-live-iso

# Boot the ISO in QEMU (native, SPICE window — better clipboard/copy-paste)
just run-live-iso-native

# Or boot in a Docker-wrapped QEMU with noVNC at http://localhost:8006
just run-live-iso
```

`just build` produces `localhost/kyth:latest`. The live ISO is written to `output/live-iso/kyth-live-latest.iso`.

### Build recipes

```bash
just build-base                           # Build kyth-base layer (CachyOS kernel)
just build                                # Build full OS image on top of kyth-base
just build-live-iso                       # Build live ISO (from :latest)
just build-live-iso testing               # Build ISO targeting the :testing image
just rebuild-live-iso                     # Full rebuild, ignores cached container layer
just run-live-iso                         # Boot ISO in Docker-wrapped QEMU (noVNC)
just run-live-iso-native                  # Boot ISO in native QEMU + SPICE
just build-qcow2                          # Build QCOW2 VM image via Bootc Image Builder
just disk-usage                           # Show Docker + output/ disk usage
just clean                                # Remove build output artefacts
just clean-docker                         # Prune Docker build cache and dangling layers
just clean-all                            # clean-output + clean-docker
just prune-live-dev                       # Reclaim space from live ISO dev cycles
just purge                                # Nuclear: reclaim maximum disk space
just lint && just format                  # shellcheck + shfmt on all .sh files
```

### Feature flags

Both default to enabled. Pass `0` to skip:

```bash
ENABLE_ANANICY=0 ENABLE_SCX=0 just build
```

### Docker group

If you get a permission denied error on the Docker socket after being added to the `docker` group:

```bash
newgrp docker
```

---

## CI

| Workflow | Trigger | Output |
|----------|---------|--------|
| Build container image | Push to `main`/`testing`, daily at 10:05 UTC, PR | `ghcr.io/mrtrick37/kyth:latest` and `:testing` |
| Build Live ISO | Manual dispatch (choose `latest` or `testing`) | `kyth-live-latest.iso` / `kyth-live-testing.iso` on Cloudflare R2 |

---

## Project layout

```text
Dockerfile                        Main OS image (layers on top of kyth-base)
Justfile                          Build orchestration — all recipes

build_base/
  Dockerfile                      Pulls kinoite-main:43, installs CachyOS kernel
  build.sh                        Kernel, initramfs, Plymouth, kargs, SDDM

build_files/
  build-live-iso.sh               Assembles squashfs + GRUB2 + UEFI/BIOS bootable ISO
  Containerfile.live              Live session container (X11 autologin, custom web installer)
  branding/
    kyth-logo.svg                 Kyth logo (with background and wordmark)
    kyth-logo-transparent.svg     Kyth K mark (transparent, for WebUI)
    cockpit-branding.css          Themed CSS for the installer WebUI
  scripts/
    packages.sh                   RPM packages, repos, dnf upgrade (Layer 1)
    thirdparty.sh                 topgrade, winetricks, scx schedulers, Homebrew (Layer 2)
    sysconfig.sh                  sysctl, audio, gaming tuning, env vars (Layer 3)
    branding.sh                   Icons, themes, Plymouth, wallpaper, welcome app (Layer 4)
    ge-proton.sh                  GE-Proton installer (Layer 5)
    mesa-git.sh                   Mesa-git GPU drivers (Layer 6)
  game-performance                CPU/GPU performance helper script
  icons/                          App icons (Outlook PWA, etc.)
  just/kyth.just                  ujust recipes shipped in the installed OS
  kyth-welcome/                   First-boot welcome app (PyQt6)
  MangoHud.conf                   System-wide MangoHud defaults
  plymouth/                       Boot splash theme (pulsating Kyth logo)
  wallpaper/                      Desktop wallpaper (SVG)
  kyth-ge-proton-update           Weekly GE-Proton update script
  kyth-duperemove                 Weekly deduplication script
  kyth-performance-mode           Toggle system performance profile
  kyth-kerver                     Print kernel/scheduler info
  kyth-device-info                Print hardware summary

disk_config/
  disk.toml                       BIB config for qcow2/raw images
  iso.toml                        BIB config for installer ISO

.github/workflows/
  build.yml                       CI: builds and publishes OS image
  build-live-iso.yml              CI: builds and publishes live ISO (manual)
```

---

## How updates work

Kyth uses bootc. On update, `bootc upgrade` pulls the new image, stages it, and makes it the default boot entry. The previous deployment stays on disk as a fallback. Automatic updates are intentionally disabled to prevent unexpected reboots.

---

## Links

- [Issues](https://github.com/mrtrick37/kyth/issues)
- [Discussions](https://github.com/mrtrick37/kyth/discussions)
- [Actions](https://github.com/mrtrick37/kyth/actions)

---

*Not affiliated with Universal Blue, Fedora, CachyOS, or anyone who actually knows what they're doing.*
