# kyth

Custom atomic gaming and development desktop OS built on Fedora Kinoite (KDE Plasma) + CachyOS kernel. Uses [bootc](https://containers.github.io/bootc/) to ship the entire OS as a container image — immutable, atomic updates, one-command rollback.

## Build Commands

```bash
just build                        # Build base image + full OS image (requires Docker)
just rebuild-live-iso             # Build the live bootable ISO (force rebuild)
just build-live-iso               # Build the live bootable ISO (uses cached container layer)
just run-live-iso-native          # Boot live ISO in QEMU with SPICE
just build-qcow2                  # Build QCOW2 VM image
just clean                        # Remove build artifacts
just purge                        # Reclaim max disk space
just lint && just format          # Shellcheck + shfmt
```

Feature flags:
```bash
ENABLE_ANANICY=0 ENABLE_SCX=0 sudo just build
```

## Common Issues

**Docker permission denied on socket:**
```bash
newgrp docker   # Activate docker group in current shell without logging out
```
(Occurs after being added to `docker` group — takes effect without full logout via `newgrp`)

## Project Layout

```text
Dockerfile              # Main OS image (layers 2+3)
Justfile                # Build orchestration
build_base/             # Layer 1: CachyOS kernel + base Fedora Kinoite 43
  Dockerfile
  build.sh
build_files/            # Layer 2+: packages, gaming tweaks, branding
  build-live-iso.sh     # Assembles squashfs + GRUB2 + ISO
  Containerfile.live    # Live session variant (custom installer)
  kyth-installer        # Graphical installer (PySide6 + Chromium kiosk)
  kyth-launch-installer # Desktop launcher for the installer
  branding/             # KythOS logos and branding CSS
  scripts/              # Build layers: packages, thirdparty, sysconfig, branding, ge-proton, mesa-git
  just/kyth.just        # ujust recipes shipped in the OS
  kyth-welcome/         # First-boot welcome app
disk_config/            # Bootc Image Builder configs
.github/workflows/      # CI: daily rebuilds at 10:05 UTC
```

## Branches

- `main` → `:latest` tag (stable)
- `testing` → `:testing` tag (active dev, may be unstable)

Switch on a running system:
```bash
sudo bootc switch ghcr.io/mrtrick37/kyth:testing
sudo bootc upgrade
```

## Key Details

- Base: `ghcr.io/ublue-os/kinoite-main:43` (Fedora 43 KDE)
- Kernel: CachyOS with BORE scheduler, sched-ext, BBRv3, NTSYNC
- GPU: Mesa-git from xxmitsu/mesa-git COPR (bleeding-edge RADV/RADEONSI)
- SELinux: permissive (Docker builds can't preserve security xattrs)
- Live ISOs published to Cloudflare R2: `kyth-live-latest.iso` / `kyth-live-testing.iso`
- GitHub: https://github.com/mrtrick37/kyth
