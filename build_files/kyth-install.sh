#!/usr/bin/bash
# kyth-install — Live ISO installer for KythOS
#
# Uses 'bootc install to-disk' to write KythOS to the selected disk.
# Pulls the final image from ghcr.io/mrtrick37/kyth:latest (requires network).
#
# Runs via the "Install KythOS" desktop icon on the live ISO.

set -euo pipefail

TARGET_IMGREF="docker://ghcr.io/mrtrick37/kyth:latest"

# Must run as root
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Run with sudo." >&2
    exit 1
fi

# ── Disk selection ────────────────────────────────────────────────────────────
# Build a list of real block devices (exclude loop, CD-ROM, and the live media)
mapfile -t DISKS < <(lsblk -dpno NAME,SIZE,MODEL \
    | grep -Ev 'loop|sr[0-9]' \
    | awk '{printf "%s\t%s %s\n", $1, $2, $3}')

if [[ ${#DISKS[@]} -eq 0 ]]; then
    if command -v kdialog &>/dev/null; then
        kdialog --title "Install KythOS" --error "No suitable disks found."
    else
        echo "ERROR: No suitable disks found." >&2
    fi
    exit 1
fi

if command -v kdialog &>/dev/null; then
    # Build kdialog --menu args: tag description tag description ...
    MENU_ARGS=()
    for entry in "${DISKS[@]}"; do
        DEV=$(echo "${entry}" | cut -f1)
        DESC=$(echo "${entry}" | cut -f2)
        MENU_ARGS+=("${DEV}" "${DEV}  ${DESC}")
    done

    SELECTED=$(kdialog \
        --title "Install KythOS" \
        --menu "Select the disk to install KythOS onto.\n\nWARNING: ALL DATA on the selected disk will be erased." \
        "${MENU_ARGS[@]}") || exit 0

    kdialog \
        --title "Install KythOS" \
        --warningyesno "ERASE ALL DATA on ${SELECTED} and install KythOS?\n\nThis cannot be undone." \
        || exit 0
else
    # Fallback: plain terminal UI
    echo ""
    echo "=== Install KythOS ==="
    echo ""
    echo "Available disks:"
    for entry in "${DISKS[@]}"; do
        echo "  ${entry}"
    done
    echo ""
    read -r -p "Enter target disk (e.g. /dev/sda): " SELECTED
    [[ -z "${SELECTED}" ]] && exit 0
    read -r -p "WARNING: ALL DATA on ${SELECTED} will be erased. Type 'yes' to confirm: " CONFIRM
    [[ "${CONFIRM}" != "yes" ]] && { echo "Aborted."; exit 0; }
fi

# ── Unmount ───────────────────────────────────────────────────────────────────
echo "Unmounting any existing mounts on ${SELECTED} ..."
umount -R /mnt 2>/dev/null || true
umount -R /sysroot 2>/dev/null || true
umount -R /target 2>/dev/null || true
# Unmount any partitions on the target disk
while IFS= read -r part; do
    umount -R "${part}" 2>/dev/null || true
done < <(lsblk -lnpo NAME "${SELECTED}" | tail -n +2)

# ── Install ───────────────────────────────────────────────────────────────────
echo "Installing KythOS to ${SELECTED} from ${TARGET_IMGREF} ..."
echo "This will take a while depending on your internet connection."
echo ""

bootc install to-disk \
    --source-imgref "${TARGET_IMGREF}" \
    --target-imgref "${TARGET_IMGREF}" \
    --filesystem btrfs \
    --wipe \
    "${SELECTED}"

echo ""
echo "Installation complete. You can now reboot into KythOS."

if command -v kdialog &>/dev/null; then
    kdialog \
        --title "Install KythOS" \
        --msgbox "Installation complete!\n\nRemove the live USB and reboot to start KythOS."
fi
