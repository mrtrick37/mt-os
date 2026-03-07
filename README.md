# mt-OS

> **⚠️ Hey, you. Yeah, you. This probably doesn't work yet. Seriously, don't install this on anything you care about. You have been warned. Proceed with chaotic enthusiasm.**

mt-OS is a custom atomic desktop Linux image built on top of [Universal Blue's Kinoite](https://universal-blue.org/) (Fedora 43, KDE Plasma, immutable). Think of it as a Bazzite-DX-style image tailored for gaming and development — opinionated, atomic, and perpetually a work in progress.

## What is this?

- **Base:** `ghcr.io/ublue-os/kinoite-main:43` — Fedora 43 KDE Plasma, atomic/immutable via bootc
- **Delivery:** OCI container image at `ghcr.io/mrtrick37/mt-os`
- **Updates:** `bootc upgrade` — like a system package update, but for your whole OS

## Planned Features (aka the dream)

- [ ] [CachyOS kernel](https://github.com/CachyOS/linux-cachyos) for better desktop/gaming performance
- [ ] Gaming tweaks (gamemode, mangohud, performance governor defaults)
- [ ] Dev tooling baked in (distrobox, VSCode, the usual suspects)
- [ ] Custom branding that doesn't embarrass anyone
- [ ] Actually boots reliably on more than one machine

## Current State

- [x] Builds
- [x] Installs (sometimes)
- [x] Boots to KDE Plasma
- [ ] Everything else

## Installation

If you're still here — respect. You can rebase an existing Fedora atomic system onto mt-OS:

```bash
bootc switch ghcr.io/mrtrick37/mt-os:latest
```

Or flash the installer ISO if you enjoy living dangerously.

## Building Locally

```bash
# 1. Build the base layer (run once, or when the base changes)
just build-base

# 2. Build the main image
just build

# 3. Build a KDE Plasma installer ISO
sudo just build-iso-plasma
```

Requires `podman` and `just`. Must run `build-base` before `build`.

## Project Structure

- `build_base/` — base image layer, pulls from `ghcr.io/ublue-os/kinoite-main:43`
- `Containerfile` — main image, runs `build_files/build.sh` on top of the base
- `build_files/build.sh` — package installs, branding, tweaks
- `disk_config/` — bootc-image-builder TOML configs for ISO/qcow2/raw artifacts
- `iso_overlay/` — grub/isolinux/os-release branding for the installer ISO
- `Justfile` — local build recipes
- `.github/workflows/` — CI: builds container image and disk artifacts

## Why?

Because stock Kinoite is great but I wanted my own thing. [Universal Blue](https://universal-blue.org/) and [Bazzite](https://bazzite.gg/) proved that building a custom atomic image is a perfectly reasonable way to do Linux in 2025.

---

*mt-OS is not affiliated with Universal Blue, Fedora, or anyone who actually knows what they're doing.*
