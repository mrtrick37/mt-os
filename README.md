# Kyth

**Kyth** is a custom atomic desktop Linux image, focused on gaming and development, built for container-native workflows. It leverages Fedora Kinoite, swaps in the CachyOS kernel, and adds a curated set of tools for both gamers and developers.

> ⚠️ Work in progress! ⚠️
> Don't install on anything you care about. Chaotic enthusiasm encouraged.

## Project Highlights

- **Base:** Fedora 43 KDE Plasma (via bootc, ublue-os/kinoite-main)
- **Kernel:** CachyOS (BORE scheduler, sched-ext, BBRv3, NTSYNC)
- **Theme:** Breeze Dark
- **Browser:** Brave
- **Gaming:** Steam, Lutris, GameMode, gamescope, mangohud, vkBasalt, umu-launcher, winetricks, libFAudio, openxr, xrandr, evtest
- **Dev Tools:** Cockpit, Visual Studio Code, Homebrew, incus/lxc, libvirt/virt-manager/virt-viewer/virt-v2v/QEMU
- **Observability:** bcc, bpftop, bpftrace, tiptop, trace-cmd, sysprof
- **AMD GPU Compute:** rocm-hip, rocm-opencl, rocm-smi
- **Flatpak/KDE:** flatpak-builder, kdeconnect, kdeplasma-addons, rom-properties-kf6

## Building Locally

Requires: `docker`, `just`, plus ISO tools for live builds (`xorriso`, `squashfs-tools`, `mtools`, `dosfstools`, `grub2-tools-minimal`).

```bash
# Build the base layer (pulls kinoite-main:43 and runs build_files/build.sh)
just build-base

# Build the live desktop ISO (auto-runs build-base if needed)
just build-live-iso

# Run the live ISO in a browser-based VM (noVNC at http://localhost:8006)
just run-live-iso

# Build Anaconda installer ISO (BIB)
just build-iso

# Build QCOW2 VM image (BIB)
just build-qcow2
```

```bash
# All recipes
just --list
```

## Install via Live ISO (Recommended)

Boot the live ISO — the full KDE desktop runs from RAM, auto-logged in as `liveuser`. Click **Install Kyth** on the desktop to launch the graphical installer.

The installer walks through:
1. **Timezone** — interactive with GeoIP auto-detection
2. **Disk selection** — automatic erase-disk or manual partitioning
3. **Install** — pulls `ghcr.io/mrtrick37/kyth:latest` and writes it to disk via `bootc`

GParted is available in the live session for partition management.

Grab the live ISO from [GitHub Releases](https://github.com/mrtrick37/kyth/releases) or build it locally.

## Rebase from an Existing Fedora Atomic System

```bash
bootc switch ghcr.io/mrtrick37/kyth:latest
```

## Updates

Once installed, Kyth updates like any bootc system:

```bash
ujust update
# or
bootc upgrade
```

Updates pull the latest image from `ghcr.io/mrtrick37/kyth:latest`. CI rebuilds and publishes a fresh image on every push to `main`.

## Project Structure

```
build_base/              Base image layer (pulls kinoite-main:43, applies branding)
build_files/
  build.sh               Kernel swap, package installs, branding, tweaks
  Containerfile.live     Live ISO variant (SDDM autologin, Anaconda WebUI installer)
  build-live-iso.sh      Assembles the live ISO (squashfs + GRUB2 + UEFI/BIOS boot)
  kyth-install-launcher  Launches the Anaconda WebUI installer from the live desktop
  kyth-anaconda-live     Wrapper that passes the Kyth kickstart to anaconda
  anaconda/kyth.ks       Kickstart: sets ostreecontainer source, network activation
disk_config/
  iso.toml               BIB config for the Anaconda installer ISO
  disk.toml              BIB config for qcow2/raw disk images
Justfile                 Local build recipes
.github/workflows/       CI: builds and publishes the container image + live ISO
```

## Why

Stock Kinoite is great. I wanted my own thing. [Universal Blue](https://universal-blue.org/) and [Bazzite](https://bazzite.gg/) showed that rolling your own atomic image is reasonable. So here we are.

---

*Kyth is not affiliated with Universal Blue, Fedora, CachyOS, or anyone who actually knows what they're doing.*
