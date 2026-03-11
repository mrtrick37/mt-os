# Kyth

Custom atomic desktop Linux image. It's an opinionated gaming and development container-native desktop OS. 


⚠️ Work in progres ⚠️

Don't install this on anything you care about. 

You've been warned. 

Proceed with chaotic enthusiasm 

## Current state: 

- Should install directly and rebase from existing bootc works (still needs love though)
- Live iso boots to plasma desktop just fine
- Working on Anaconda installer fixes


## What's in it

- **Base:** `ghcr.io/ublue-os/kinoite-main:43` — Fedora 43 KDE Plasma via bootc
- **Kernel:** [CachyOS kernel](https://github.com/CachyOS/linux-cachyos) — BORE scheduler, sched-ext, BBRv3, NTSYNC
- **Theme:** Breeze Dark by default
- **Browser:** Brave

### Gaming
- Steam, Lutris, GameMode
- gamescope + gamescope-shaders, mangohud (x86_64 + i686), vkBasalt (x86_64 + i686)
- umu-launcher, winetricks (always latest from upstream)
- libFAudio, libobs_vkcapture/glcapture, openxr, xrandr, evtest

### Developer Tooling
- **Cockpit** — machines, podman, networkmanager, ostree, selinux, storaged
- **Visual Studio Code** — pre-installed
- **Homebrew** — system-wide at `/home/linuxbrew/.linuxbrew`; any wheel user can run `brew`
- **podman-compose**, **podman-tui**, **podman-machine**
- **incus**, **lxc** — system containers
- **libvirt**, **virt-manager**, **virt-viewer**, **virt-v2v**, **QEMU** — full VM stack
- **bcc**, **bpftop**, **bpftrace**, **tiptop**, **trace-cmd**, **sysprof** — system observability
- **rocm-hip**, **rocm-opencl**, **rocm-smi** — AMD GPU compute
- **flatpak-builder**, **git-subtree**, **git-svn**, **p7zip**, **tmux**

### KDE Integrations
- kdeconnect, kdeplasma-addons, rom-properties-kf6

## Installation

### Live ISO (recommended)

Boot the live ISO to try Kyth without installing. The full KDE desktop runs from RAM. Click **Install Kyth** on the desktop to launch the graphical installer.

The installer wizard walks through:
1. **Timezone** — interactive world map with GeoIP auto-detection
2. **Disk selection** — automatic erase-disk mode by default; manual partitioning available
3. **Install** — pulls `ghcr.io/mrtrick37/kyth:latest` and writes it to disk via `bootc`

GParted is available in the live session for pre-install partition management.

Grab the live ISO from [GitHub Releases](https://github.com/mrtrick37/kyth/releases) or build it locally (see below).

### Rebase from an existing Fedora atomic system

```bash
bootc switch ghcr.io/mrtrick37/kyth:latest
```

### Installer ISO

For a traditional Anaconda installer experience, use the installer ISO instead.

## Building Locally

Requires `podman`, `just`.

```bash
# 1. Build the base layer
just build-base

# 2. Build the main image
just build

# 3a. Build the live desktop ISO
#     Also requires: xorriso squashfs-tools mtools dosfstools grub2-tools-minimal
just build-live-iso

# 3b. Run the live ISO in a VM (UEFI, web UI)
just run-live-iso

# 3c. Build the Anaconda installer ISO
just build-iso

# 3d. Build a QCOW2 VM image
just build-qcow2
```

```bash
# All recipes
just --list
```

## Project Structure

```
build_base/              Base image layer (pulls kinoite-main:43, applies branding)
Containerfile            Main image (runs build_files/build.sh on top of base)
build_files/
  build.sh               Kernel swap, package installs, branding, tweaks
  Containerfile.live     Live ISO variant (adds live session, Calamares installer)
  build-live-iso.sh      Assembles the live ISO (squashfs + GRUB2 + UEFI/BIOS boot)
  kyth-calamares-install.sh   Calamares shellprocess: runs bootc install, applies timezone
  kyth-install-launcher       Launches Calamares as root from the live desktop
  kyth-install.sh       Fallback terminal installer
  calamares/             Calamares wizard config (settings, modules, branding)
disk_config/
  iso-kde.toml           BIB config for the Anaconda KDE installer ISO
  iso.toml               BIB config for the Anaconda installer ISO
  disk.toml              BIB config for qcow2/raw disk images
iso_overlay/             GRUB/isolinux/os-release branding for installer ISOs
Justfile                 Local build recipes
.github/workflows/       CI: builds and publishes the container image
```

## Updates

Once installed, Kyth updates like any bootc system:

```bash
ujust update
# or
bootc upgrade
```

Updates pull the latest image from `ghcr.io/mrtrick37/kyth:latest`. The CI rebuilds and publishes a fresh image (including all upstream package updates) on every push to `main`.

## Why

Stock Kinoite is great. I wanted my own thing. [Universal Blue](https://universal-blue.org/) and [Bazzite](https://bazzite.gg/) showed that rolling your own atomic image is reasonable. So here we are.

---

*Kyth is not affiliated with Universal Blue, Fedora, CachyOS, or anyone who actually knows what they're doing.*
