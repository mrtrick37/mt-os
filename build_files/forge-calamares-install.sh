#!/usr/bin/bash
# forge-calamares-install — Called by Calamares shellprocess module.
#
# The Calamares partition + mount modules have already partitioned the chosen
# disk and mounted it under /tmp/calamares-root.  This script:
#   1. Derives the disk device from those mounts (e.g. /dev/sda2 → /dev/sda)
#   2. Unmounts /tmp/calamares-root so bootc can take over the disk
#   3. Runs 'bootc install to-disk' to pull and write Forge
#   4. Mounts the installed root and applies the selected timezone

set -euo pipefail

TARGET_IMGREF="ghcr.io/mrtrick37/forge:latest"
CALAMARES_ROOT="/tmp/calamares-root"

# Timezone passed as $1 by Calamares via @@timezone@@ substitution.
# Guard against the literal placeholder in case the locale module was skipped.
TIMEZONE="${1:-}"
if [[ "${TIMEZONE}" == *"@@"* ]]; then
    TIMEZONE=""
fi

# ── Find the target disk ──────────────────────────────────────────────────────
DISK=""

# Primary method: derive disk from what the mount module mounted to calamares-root
if findmnt -n -o SOURCE "${CALAMARES_ROOT}" &>/dev/null; then
    ROOT_PART=$(findmnt -n -o SOURCE "${CALAMARES_ROOT}" | head -1)
    # lsblk PKNAME gives the parent disk of a partition (e.g. sda1 → sda)
    PARENT=$(lsblk -no PKNAME "${ROOT_PART}" 2>/dev/null | head -1)
    [[ -n "${PARENT}" ]] && DISK="/dev/${PARENT}"
fi

# Fallback: /tmp/forge-target-disk written by the legacy kdialog launcher
if [[ -z "${DISK}" ]] && [[ -f /tmp/forge-target-disk ]]; then
    DISK=$(tr -d '[:space:]' < /tmp/forge-target-disk)
fi

if [[ -z "${DISK}" ]]; then
    echo "ERROR: Could not determine the target disk." >&2
    echo "       Nothing was mounted to ${CALAMARES_ROOT}." >&2
    exit 1
fi

if [[ ! -b "${DISK}" ]]; then
    echo "ERROR: ${DISK} is not a block device." >&2
    exit 1
fi

echo "=== Forge 43 Installation ==="
echo "Target disk : ${DISK}"
echo "Image       : ${TARGET_IMGREF}"
[[ -n "${TIMEZONE}" ]] && echo "Timezone    : ${TIMEZONE}"
echo ""

# ── Unmount calamares-root so bootc can repartition the disk ─────────────────
echo "Unmounting temporary partitions..."
umount -R -l "${CALAMARES_ROOT}" 2>/dev/null || true

# ── Install ───────────────────────────────────────────────────────────────────
echo "Pulling image and writing to disk — this will take a while..."
echo ""

bootc install to-disk \
    --target-imgref "${TARGET_IMGREF}" \
    "${DISK}"

echo ""
echo "=== Installation complete ==="

# ── Apply timezone to the installed ostree deployment ─────────────────────────
# bootc creates three partitions: EFI, /boot, root (xfs — the largest).
# Mount the root partition and write /etc/localtime into the ostree deployment.
if [[ -n "${TIMEZONE}" ]]; then
    echo "Applying timezone: ${TIMEZONE}"

    # Validate timezone exists in the live ISO's zoneinfo database
    if [[ ! -f "/usr/share/zoneinfo/${TIMEZONE}" ]]; then
        echo "WARNING: Unknown timezone '${TIMEZONE}' — skipping." >&2
    else
        # Find the root partition: the xfs partition on the target disk
        ROOT_PART=$(lsblk -no NAME,FSTYPE "${DISK}" | \
            awk '$2=="xfs" {last=$1} END { if (last) print "/dev/"last }')

        if [[ -n "${ROOT_PART}" ]] && [[ -b "${ROOT_PART}" ]]; then
            SYSROOT=/tmp/forge-installed-sysroot
            mkdir -p "${SYSROOT}"
            mount "${ROOT_PART}" "${SYSROOT}"

            # Locate the ostree deployment's /etc
            DEPLOY_ETC=$(find "${SYSROOT}/ostree/deploy"/*/deploy/*/etc \
                -maxdepth 0 -type d 2>/dev/null | head -1)

            if [[ -n "${DEPLOY_ETC}" ]]; then
                ln -sf "/usr/share/zoneinfo/${TIMEZONE}" "${DEPLOY_ETC}/localtime"
                echo "Timezone written to ${DEPLOY_ETC}/localtime"
            else
                echo "WARNING: Could not locate ostree deployment etc — timezone not applied." >&2
            fi

            umount "${SYSROOT}"
        else
            echo "WARNING: Could not find root partition on ${DISK} — timezone not applied." >&2
        fi
    fi
fi
