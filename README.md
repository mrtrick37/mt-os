# Kyth

An atomic gaming and development desktop built on Fedora Kinoite with the CachyOS kernel. Immutable OS, Anaconda WebUI installer, ships as a bootable live ISO.

> Work in progress. Don't install on anything you care about.

---

## What it is

Kyth is a custom [bootc](https://containers.github.io/bootc/) image. The entire OS is a container image built with Docker, installed to disk via the Anaconda WebUI installer, and updated atomically. Rolling back is one command.

**Base:** Fedora 43 KDE Plasma (`ublue-os/kinoite-main:43`)
**Kernel:** CachyOS — BORE scheduler, sched-ext, BBRv3, NTSYNC, latency-tuned for gaming
**GPU drivers:** Mesa-git (bleeding edge RADV/RADEONSI from `@mesa/mesa` COPR)
**Display:** KDE Plasma on Wayland
**Installer:** Anaconda WebUI (ostreecontainer — pulls the OS image from the registry at install time)
**Theme:** Breeze Dark with Kyth branding, Plymouth boot splash, and Tokyo Night accent colors

---

## What's included

### Gaming

- Steam, Lutris, GameMode, gamescope, MangoHud, vkBasalt
- umu-launcher, winetricks (pinned upstream release), libFAudio, OpenXR
- RADV_PERFTEST=gpl — Vulkan Graphics Pipeline Library enabled by default
- NTSYNC udev rules (faster Wine sync primitives)
- AMD GPU high-performance power profile during gameplay (GameMode)
- `game-performance` and `zink-run` helper wrappers for quick launch testing/tuning
- Weekly `duperemove` timer for reclaiming duplicate Steam/Wine data on supported filesystems

### Development

- Visual Studio Code, Brave browser
- GitHub CLI (`gh`)
- Homebrew (system-wide, wheel group owns `/home/linuxbrew`)
- Cockpit (web-based system management)
- libvirt / virt-manager / QEMU / incus + LXC
- Docker

### Observability

- bcc, bpftop, bpftrace, trace-cmd, tiptop, sysprof, radeontop

### System tuning

- vm.swappiness=10, THP=madvise, TCP BBRv3, zram (min(RAM/2, 8 GB) zstd)
- GameMode CPU/GPU governor profiles
- WiFi power-save disabled system-wide
- spice-vdagent for automatic display resolution in VMs
- PowerDevil DDC/CI monitor control disabled by default on Plasma sessions to reduce AMD display/power-management instability
- `libddcutil` display-watch threads disabled system-wide
- `kyth-kerver` and matching `ujust` recipes for quick system/tuning inspection
- `ujust device-info`, `ujust install-lact`, and `ujust install-input-remapper`

---

## Branches and image tags

| Branch | Image tag | Purpose |
|--------|-----------|---------|
| `main` | `:latest` | Stable (relatively speaking) |
| `testing` | `:testing` | Active development — may be unstable |

Both branches rebuild daily at 10:05 UTC to pick up the latest packages regardless of code changes.

To switch between them on an installed system:

```bash
# Switch to testing
sudo bootc switch ghcr.io/mrtrick37/kyth:testing

# Switch back to stable
sudo bootc switch ghcr.io/mrtrick37/kyth:latest
```

---

## Install

### Live ISO (recommended)

| Channel | Download | Description |
|---------|----------|-------------|
| **Stable** | [kyth-live-latest.iso](https://pub-9a3cc72972ea44c4ae7504ee7cda1fa6.r2.dev/kyth-live-latest.iso) | Built from `main` |
| **Testing** | [kyth-live-testing.iso](https://pub-9a3cc72972ea44c4ae7504ee7cda1fa6.r2.dev/kyth-live-testing.iso) | Built from `testing` — may be unstable |

1. Flash the ISO to a USB drive (`dd`, Balena Etcher, Ventoy, etc.)
2. Boot it — KDE Plasma loads automatically, no login required
3. Click **Install Kyth** on the desktop
4. The Anaconda WebUI opens in Firefox — configure language, disk, timezone, and user account
5. Click **Install** — the OS image is pulled from the container registry and written to disk
6. Reboot into the installed system

Minimum 8 GB RAM recommended for the live session and installer. An active network connection is required — the installer pulls the OS image (~4 GB) from the registry at install time.

The live ISO autologins to the desktop as `liveuser`; no password is required.

### Rebase from an existing Fedora atomic system

```bash
bootc switch ghcr.io/mrtrick37/kyth:latest
```

---

## Updates

```bash
sudo bootc upgrade
```

Kyth rebuilds and publishes a new image on every push to `main` and `testing`. Updates are atomic — the previous deployment is kept as a fallback and can be selected at the GRUB menu.

---

## Build locally

**Requirements:** `docker`, `just`, `xorriso`, `squashfs-tools`, `mtools`, `dosfstools`, `grub2-tools-minimal`

```bash
# Install build tools
sudo dnf install -y just xorriso squashfs-tools mtools dosfstools grub2-tools-minimal

# Step 1 — build the OS image
sudo just build

# Step 2 — build the live ISO (Anaconda installer)
just build-anaconda-iso

# Boot the ISO in QEMU for testing
just run-anaconda-iso-native
```

`sudo just build` produces `localhost/kyth:latest`. `just build-anaconda-iso` builds a separate, stable installer runtime image (default base: `ghcr.io/ublue-os/kinoite-main:43`) and assembles the bootable ISO. The installer still deploys Kyth from the registry (`ghcr.io/mrtrick37/kyth:<tag>`). The ISO is written to `output/live-iso/kyth-live-anaconda-latest.iso`.

To override installer runtime base explicitly:

```bash
INSTALLER_BASE_IMAGE=ghcr.io/ublue-os/kinoite-main:43 just rebuild-anaconda-iso
```

### Useful build recipes

```bash
just rebuild-anaconda-iso          # Full rebuild (ignores cached container layer)
just build-anaconda-iso testing    # Build from the testing image
just run-anaconda-iso-native       # Boot ISO in QEMU with SPICE display
just build-qcow2                   # Build QCOW2 VM image via Bootc Image Builder
just clean                         # Remove build artifacts
just purge                         # Reclaim max disk space
just lint && just format           # Shellcheck + shfmt
```

### Feature flags

Both are enabled by default. Pass `0` to skip them if the packages are unavailable:

```bash
ENABLE_ANANICY=0 ENABLE_SCX=0 sudo just build
```

---

## Project layout

```text
Dockerfile                        Main OS image (layers on top of kyth-base)
Justfile                          Build orchestration — all recipes

build_base/
  Dockerfile                      Pulls kinoite-main:43, runs build.sh
  build.sh                        CachyOS kernel, initramfs, Plymouth, kargs, SDDM

build_files/
  build.sh                        Packages, gaming tweaks, skel, icons, dev tools
  build-anaconda-iso.sh           Assembles squashfs + GRUB2 + UEFI/BIOS bootable ISO
  Containerfile.anaconda          Stable installer runtime container (X11 autologin, Anaconda WebUI)
  anaconda/
    kyth.ks                       Kickstart — ostreecontainer source for :latest
    kyth-testing.ks               Kickstart — ostreecontainer source for :testing
    kyth-launch-anaconda          Desktop launcher script (calls liveinst)
    kyth-anaconda-debug           Debug/log collection helper
  branding/
    kyth-logo.svg                 Kyth logo (with background and wordmark)
    kyth-logo-transparent.svg     Kyth K mark (transparent, for Cockpit/WebUI)
    cockpit-branding.css          Tokyo Night themed CSS for the Anaconda WebUI
  scripts/
    packages.sh                   RPM packages, repos, dnf upgrade
    thirdparty.sh                 Third-party binaries (topgrade, winetricks, SCX)
    sysconfig.sh                  System configuration (sysctl, audio, gaming tuning)
    branding.sh                   Icons, themes, Plymouth, wallpaper, welcome app
    ge-proton.sh                  GE-Proton installer
    mesa-git.sh                   Bleeding-edge Mesa GPU drivers
  plymouth/                       Boot splash theme (pulsating Kyth logo)
  wallpaper/                      Desktop wallpaper (SVG)
  just/kyth.just                  ujust recipes shipped in the installed OS
  kyth-welcome/                   First-boot welcome app

disk_config/
  disk.toml                       BIB config for qcow2/raw disk images
  iso.toml                        BIB config for installer ISO builds

.github/workflows/
  build.yml                       CI: builds and publishes OS image on push
  build-anaconda-iso.yml          CI: builds and publishes Anaconda live ISO
```

---

## How updates work

Kyth uses [bootc](https://containers.github.io/bootc/) — the OS is a container image. On update, `bootc upgrade` pulls the new image, stages it, and makes it the default boot entry. The previous deployment stays on disk as a fallback. There is no package manager on the running system; all changes go through the image build.

For user-installed applications use Flatpak (via Discover) or Homebrew.

---

## Links

- [Issues](https://github.com/mrtrick37/kyth/issues)
- [Discussions](https://github.com/mrtrick37/kyth/discussions)
- [Actions](https://github.com/mrtrick37/kyth/actions)

---

*Not affiliated with Universal Blue, Fedora, CachyOS, or anyone who actually knows what they're doing.*
