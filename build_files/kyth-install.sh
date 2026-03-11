#!/usr/bin/bash
# kyth-install — Live ISO installer for Kyth
#
# Uses 'bootc install to-disk' to write Kyth to the selected disk.
# Pulls the final image from ghcr.io/mrtrick37/kyth:latest (requires network).
#
# Runs via the "Install Kyth" desktop icon on the live ISO.

set -euo pipefail

TARGET_IMGREF="ghcr.io/mrtrick37/kyth:latest"

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
        kdialog --title "Install Kyth" --error "No suitable disks found."
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
        --title "Install Kyth" \
        --menu "Select the disk to install Kyth onto.\n\nWARNING: ALL DATA on the selected disk will be erased." \
        "${MENU_ARGS[@]}") || exit 0

    kdialog \
        --title "Install Kyth" \
        --warningyesno "ERASE ALL DATA on ${SELECTED} and install Kyth?\n\nThis cannot be undone." \
        || exit 0
else
    # Fallback: plain terminal UI
    echo ""
    echo "=== Install Kyth ==="
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

# ── Install ───────────────────────────────────────────────────────────────────
echo "Installing Kyth to ${SELECTED} from ${TARGET_IMGREF} ..."
echo "This will take a while depending on your internet connection."
echo ""

bootc install to-disk \
    --source-imgref "${TARGET_IMGREF}" \
    --target-imgref "${TARGET_IMGREF}" \
    "${SELECTED}"

echo ""
echo "Installation complete. You can now reboot into Kyth."

if command -v kdialog &>/dev/null; then
    kdialog \
        --title "Install Kyth" \
        --msgbox "Installation complete!\n\nRemove the live USB and reboot to start Kyth."
fi
