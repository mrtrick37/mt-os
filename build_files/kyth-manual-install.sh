#!/usr/bin/bash
# kyth-manual-install.sh — Manual installer for KythOS from a live ISO session.
#
# Use this when the graphical installer is unavailable (e.g. broken Wayland).
# This is the CLI equivalent of the graphical install path: it calls
# 'bootc install to-disk' directly on the host, using the OCI image that is
# bundled inside the live ISO squashfs at /usr/share/kyth/image.
# No network download, no podman, no container mount gymnastics.
#
# Usage:
#   sudo ./kyth-manual-install.sh [TARGET_DISK]
#
# Default TARGET_DISK: /dev/nvme0n1

set -euo pipefail

TARGET="${1:-/dev/nvme0n1}"
BUNDLED_IMGREF="oci:/usr/share/kyth/image"
TARGET_IMGREF="ghcr.io/mrtrick37/kyth:latest"

# ── Sanity checks ─────────────────────────────────────────────────────────────

[[ $EUID -eq 0 ]]  || { echo "ERROR: Run as root (sudo)."; exit 1; }
[[ -b "$TARGET" ]] || { echo "ERROR: $TARGET is not a block device."; exit 1; }

if ! command -v bootc &>/dev/null; then
    echo "ERROR: 'bootc' not found. Run this script from the KythOS live ISO."
    exit 1
fi

BUNDLED_PATH="${BUNDLED_IMGREF#oci:}"
if [[ ! -d "$BUNDLED_PATH" ]]; then
    echo "ERROR: Bundled OS image not found at $BUNDLED_PATH."
    echo "       This script must be run from the KythOS live ISO."
    exit 1
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "=== KythOS Manual Installer ==="
echo ""
echo "  Install to : $TARGET"
echo "  Source     : $BUNDLED_IMGREF  (bundled in live ISO — no download needed)"
echo "  Target ref : $TARGET_IMGREF"
echo ""
echo "  bootc will erase $TARGET and create its own partition layout:"
echo "    p1  1MB    BIOS boot"
echo "    p2  512MB  EFI"
echo "    p3  rest   Root (Btrfs)"
echo ""
echo "WARNING: ALL DATA on $TARGET will be erased."
echo ""
read -r -p "Type 'yes' to continue: " CONFIRM
[[ "$CONFIRM" == "yes" ]] || { echo "Aborted."; exit 0; }

# ── Install ───────────────────────────────────────────────────────────────────

echo ""
echo "==> Installing KythOS to $TARGET..."
echo ""

bootc install to-disk            \
    --source-imgref "$BUNDLED_IMGREF" \
    --target-imgref "$TARGET_IMGREF"  \
    --filesystem    btrfs             \
    --skip-fetch-check                \
    "$TARGET"

# ── Done ──────────────────────────────────────────────────────────────────────

echo ""
echo "Installation complete!"
echo ""
echo "Remove the live media and reboot to start KythOS."
echo ""
