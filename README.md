# mt-OS

> **⚠️ Hey, you. Yeah, you. This probably doesn't work (in fact I know it doesn't currently boot with the Cachy Kernel). Seriously, don't install this on anything you care about. You have been warned. Proceed with chaotic enthusiasm.**

mt-OS is a custom atomic desktop Linux image built on top of [Universal Blue's Kinoite](https://universal-blue.org/) (Fedora 43, KDE Plasma, immutable). Think of it as highly customized gaming and development powerhouse baked into an atomic image — opinionated, fast, and perpetually a work in progress.

## What is this?

- **Base:** `ghcr.io/ublue-os/kinoite-main:43` — Fedora 43 KDE Plasma, atomic/immutable via bootc
- **Kernel:** [CachyOS kernel](https://github.com/CachyOS/linux-cachyos) (BORE scheduler, sched-ext, BBRv3, NTSYNC) for better desktop and gaming performance
- **Delivery:** OCI container image at `ghcr.io/mrtrick37/mt-os`
- **Updates:** `bootc upgrade` — like a system package update, but for your whole OS

## What's included

### Gaming
- **gamescope** — Valve's micro-compositor for HDR, upscaling, and frame limiting
- **mangohud** — in-game performance overlay (x86_64 + i686)
- **vkBasalt** — post-processing layer for Vulkan games (x86_64 + i686)
- **umu-launcher** — unified game launcher (Proton/Wine wrapper)
- **steam** — it's Steam
- **lutris** — open gaming platform
- **gamemode** — CPU/GPU performance profile switching on game launch
- **winetricks** — always-latest from upstream
- **libFAudio**, **libobs_vkcapture/glcapture**, **openxr** — supporting cast

### Developer Tooling (bluefin-dx-style)
- **cockpit** (bridge, machines, networkmanager, ostree, podman, selinux, storaged, system)
- **Docker CE** — repo added, disabled by default; install with `--enablerepo=docker-ce-stable`
- **Visual Studio Code** — repo added, disabled by default; install with `--enablerepo=code`
- **podman-compose**, **podman-tui**, **podman-machine**
- **incus**, **incus-agent**, **lxc** — system containers
- **libvirt**, **virt-manager**, **virt-viewer**, **virt-v2v** — full VM stack
- **QEMU** (with spice, virtio-gpu, usb-redirect, x86 core, user-static)
- **bcc**, **bpftop**, **bpftrace**, **tiptop**, **trace-cmd**, **sysprof** — system observability
- **rocm-hip**, **rocm-opencl**, **rocm-smi** — AMD GPU compute
- **flatpak-builder**, **git-subtree**, **git-svn**, **p7zip**, **tmux**, and more

### KDE integrations
- **kdeconnect**, **kdeplasma-addons**, **rom-properties-kf6**

## Current State

- [x] Builds
- [x] Installs
- [x] Boots to KDE Plasma
- [x] CachyOS kernel (BORE scheduler)
- [x] Gaming stack (Steam, gamescope, mangohud, vkBasalt, umu-launcher, lutris)
- [x] Full dev tooling (Docker, VSCode, libvirt, cockpit, bpf tools, ROCm)
- [ ] Actually tested on more than one machine
- [ ] Everything else

## Installation

If you're still here — respect. You can rebase an existing Fedora atomic system onto mt-OS:

```bash
bootc switch ghcr.io/mrtrick37/mt-os:latest
```

Or build and flash the installer ISO locally if you enjoy living dangerously.

## Building Locally

```bash
# Full pipeline — builds base, main image, and KDE Plasma installer ISO
sudo just bip
```

Or step by step:

```bash
# 1. Build the base layer (pulls kinoite-main:43, applies branding)
just build-base

# 2. Build the main image (installs all packages, CachyOS kernel, gaming tweaks)
just build

# 3. Build the KDE Plasma installer ISO
sudo just bip
```

Requires `podman` and `just`.

## Project Structure

- `build_base/` — base image layer, pulls from `ghcr.io/ublue-os/kinoite-main:43`
- `Containerfile` — main image, runs `build_files/build.sh` on top of the base
- `build_files/build.sh` — kernel swap, package installs, branding, tweaks
- `disk_config/` — bootc-image-builder TOML configs for ISO/qcow2/raw artifacts
- `iso_overlay/` — grub/isolinux/os-release branding for the installer ISO
- `Justfile` — local build recipes (`just --list` for all commands)
- `.github/workflows/` — CI: builds and publishes the container image

## Why?

There are genuinely great gaming Linux images out there. [Bazzite](https://bazzite.gg/) is phenomenal for gaming. [Bluefin](https://projectbluefin.io/) is a dream for developers. [Nobara](https://nobaraproject.org/) patches things upstream won't touch. Each one does something really well — and none of them did everything I wanted at the same time.

The alternative was distro hopping every time I needed a different tool for a different task. Gaming session? Boot Bazzite. Dev work? Switch to Bluefin. Deep system stuff? Maybe something else. That gets old fast.

So instead of choosing, mt-OS just takes the best parts of each: the gaming stack from Bazzite, the developer tooling philosophy from Bluefin-DX, the CachyOS kernel for performance, and the atomic/immutable foundation from Universal Blue — all baked into one image that doesn't make you compromise.

It's not for everyone. But it's exactly what I was looking for.

---

*mt-OS is not affiliated with Universal Blue, Fedora, CachyOS, or anyone who actually knows what they're doing.*
