# Kyth

An atomic gaming and development desktop built on Fedora Kinoite with the CachyOS kernel. Immutable OS, graphical installer, ships as a bootable live ISO.

> Work in progress. Don't install on anything you care about.

---

## What it is

Kyth is a custom [bootc](https://containers.github.io/bootc/) image. The entire OS is a container image built with Docker, installed to disk with `bootc`, and updated atomically. Rolling back is one command.

**Base:** Fedora 43 KDE Plasma (`ublue-os/kinoite-main:43`)
**Kernel:** CachyOS — BORE scheduler, sched-ext, BBRv3, NTSYNC, latency-tuned for gaming
**Display:** KDE Plasma on Wayland
**Theme:** Breeze Dark with Kyth branding and boot splash

---

## What's included

### Gaming

- Steam, Lutris, GameMode, gamescope, MangoHud, vkBasalt
- umu-launcher, winetricks, libFAudio, OpenXR
- NTSYNC udev rules (faster Wine sync primitives)

### Development

- Visual Studio Code, Brave browser
- Homebrew (system-wide, wheel group)
- Cockpit (web-based system management)
- libvirt / virt-manager / QEMU / virt-v2v / incus + LXC
- Docker

### Observability

- bcc, bpftop, bpftrace, trace-cmd, tiptop, sysprof

### System tuning

- vm.swappiness=10, THP=madvise, TCP BBRv3, zram (min(RAM/2, 8 GB) zstd)
- scx_lavd-ready (sched-ext userspace scheduler)
- GameMode CPU/GPU governor profiles
- WiFi power-save disabled system-wide
- spice-vdagent for automatic display resolution in VMs

---

## Install

### Live ISO (recommended)

1. Download the ISO from [Releases](https://github.com/mrtrick37/kyth/releases) or build it locally
2. Boot it — KDE Plasma loads automatically, no login required
3. Click **Install Kyth** on the desktop
4. Follow the installer: timezone → disk → user → install
5. Reboot into the installed system

Minimum 8 GB RAM recommended for the live session and installer.

### Rebase from an existing Fedora atomic system

```bash
bootc switch ghcr.io/mrtrick37/kyth:latest
```

---

## Updates

```bash
bootc upgrade
```

Kyth rebuilds and publishes a new image on every push to `main`. Updates are atomic — the previous deployment is kept as a fallback and can be selected at the GRUB menu.

---

## Build locally

**Requirements:** `docker`, `just`, `xorriso`, `squashfs-tools`, `mtools`, `dosfstools`, `grub2-tools-minimal`, `skopeo`

```bash
# Install build tools
sudo dnf install -y just xorriso squashfs-tools mtools dosfstools grub2-tools-minimal skopeo

# Step 1 — build the OS image (requires root for Docker)
sudo just build

# Step 2 — assemble the live ISO
just build-live-iso

# List all available recipes
just --list
```

These are two separate steps. `sudo just build` produces `localhost/kyth:latest`. `just build-live-iso` wraps it in a live session layer and assembles the bootable ISO. If you re-run `just build-live-iso` after a fresh `sudo just build`, it automatically detects that the base image changed and rebuilds the live layer — no extra flags needed.

The live ISO is written to `output/live-iso/kyth-live.iso`.

---

## Project layout

```text
build_base/
  Containerfile        Pulls kinoite-main:43, runs build_base/build.sh
  build.sh             CachyOS kernel, initramfs, Plymouth boot splash, kargs, SDDM

build_files/
  build.sh             Packages, gaming tweaks, skel, icons, branding, dev tools
  Containerfile.live   Live ISO variant — X11 autologin, Calamares installer
  build-live-iso.sh    Assembles squashfs + GRUB2 + UEFI/BIOS bootable ISO
  calamares/           Installer branding and module configuration
  calamares-modules/   bootcinstall and umount Python modules for Calamares
  plymouth/            Boot splash theme (Tokyo Night, Kyth logo + spinner)
  wallpaper/           Kyth desktop wallpaper (SVG)

disk_config/
  disk.toml            BIB config for qcow2/raw disk images
  iso.toml             BIB config for Anaconda installer ISO

Dockerfile             Assembles the final kyth:latest image from the base
Justfile               All build, run, and clean recipes
.github/workflows/     CI: builds and publishes image + live ISO on push to main
```

---

## How updates work

Kyth uses [bootc](https://containers.github.io/bootc/) — the OS is a container image. On update, `bootc upgrade` pulls the new image, stages it, and makes it the default boot entry. The previous deployment stays on disk as a fallback. There is no package manager on the running system; all changes go through the image build.

For user-installed applications use Flatpak (via Discover) or Homebrew.

---

*Not affiliated with Universal Blue, Fedora, CachyOS, or anyone who actually knows what they're doing.*
