#!/bin/bash
set -euo pipefail

# Docker build layers do not preserve security xattrs, so all files deployed
# via bootc/ostree end up unlabeled.  SELinux enforcing then denies access to
# unlabeled files, breaking dbus-broker and the entire session at first boot.
# Permissive mode logs denials without blocking — correct labeling requires
# either a Podman/buildah build (which preserves xattrs) or a live relabel.
sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config

# Apply KythOS branding to the base image
cat > /etc/os-release <<'EOF' || true
NAME="KythOS"
PRETTY_NAME="KythOS 44"
ID=fedora
VERSION_ID="44"
ANSI_COLOR="0;34"
HOME_URL="https://github.com/mrtrick37/kyth"
SUPPORT_URL="https://github.com/mrtrick37/kyth/discussions"
BUG_REPORT_URL="https://github.com/mrtrick37/kyth/issues"
EOF

echo "KythOS base customization applied"

# ── CachyOS kernel ────────────────────────────────────────────────────────────
# Install with --noscripts to skip the %posttrans that calls rpm-ostree
# kernel-install → dracut, which fails in container builds due to EXDEV errors
# when dracut tries to rename tmp files across the overlay filesystem.
# We run dracut ourselves below with full control over the environment.
dnf5 copr enable -y bieszczaders/kernel-cachyos
dnf5 install -y --setopt=tsflags=noscripts kernel-cachyos-modules

CACHYOS_KVER=$(basename "$(echo /usr/lib/modules/*cachyos*)")
depmod -a "${CACHYOS_KVER}"

dnf5 install -y --setopt=tsflags=noscripts --skip-unavailable \
    kernel-cachyos \
    kernel-cachyos-core \
    kernel-cachyos-devel

depmod -a "${CACHYOS_KVER}"

# Remove every non-CachyOS kernel from /usr/lib/modules/ so bootc sees
# exactly one kernel (it errors out if multiple subdirectories are present).
for kdir in /usr/lib/modules/*/; do
    kver=$(basename "$kdir")
    if [[ "$kver" != *cachyos* ]]; then
        echo "Removing non-CachyOS kernel: ${kver}"
        rm -rf "$kdir"
    fi
done
rpm -qa | grep -E '^kernel' | grep -v cachyos | xargs -r rpm --nodeps -e 2>/dev/null || true

# Ensure vmlinuz is in the OSTree-expected location
# (kernel RPMs may put it in /boot; bootc needs it at /usr/lib/modules/<kver>/vmlinuz)
if [ ! -f "/usr/lib/modules/${CACHYOS_KVER}/vmlinuz" ]; then
    if [ -f "/boot/vmlinuz-${CACHYOS_KVER}" ]; then
        cp --no-preserve=all "/boot/vmlinuz-${CACHYOS_KVER}" "/usr/lib/modules/${CACHYOS_KVER}/vmlinuz" 2>/dev/null
    fi
fi

# Write dracut config — force the ostree module required for bootc deployments.
# Without it the initramfs cannot find or mount the root filesystem.
mkdir -p /etc/dracut.conf.d
cat > /etc/dracut.conf.d/99-kyth.conf <<'DRACUTEOF'
add_dracutmodules+=" ostree "
# virtio_blk/virtio_scsi/ahci are built into the CachyOS kernel (=y),
# so add_drivers has no effect for them. Kept for documentation.
add_drivers+=" virtio_blk virtio_scsi virtio_pci nvme ahci "
DRACUTEOF

TMPDIR=/var/tmp dracut \
    --no-hostonly \
    --kver "${CACHYOS_KVER}" \
    --force \
    "/usr/lib/modules/${CACHYOS_KVER}/initramfs" \
    2> >(grep -Ev 'xattr|fail to copy' >&2)

dnf5 copr disable -y bieszczaders/kernel-cachyos

# Set kernel args for the installed system via bootc kargs.d.
# quiet: suppress kernel log spam on the console.
# splash: activate Plymouth so the boot splash is shown.
mkdir -p /usr/lib/bootc/kargs.d
cat > /usr/lib/bootc/kargs.d/99-kyth.toml <<'KARGSEOF'
kargs = ["quiet", "splash", "mitigations=off", "threadirqs"]
KARGSEOF

# ── SDDM — ensure graphical target ───────────────────────────────────────────
systemctl enable sddm 2>/dev/null || true
systemctl set-default graphical.target 2>/dev/null || true

# Mask bootloader-update.service: this ostree/rpm-ostree service tries to
# update the bootloader on every boot but always fails in our bootc image,
# producing noisy FAILED entries in the boot log.
systemctl mask bootloader-update.service 2>/dev/null || true

# Mask systemd-remount-fs.service: on bootc/ostree the root filesystem is
# already mounted correctly by the bootloader; the remount always fails with
# exit code 32 producing a FAILED unit every boot.
systemctl mask systemd-remount-fs.service 2>/dev/null || true

# ── SDDM display server: Wayland by default ───────────────────────────────────
# Keep the on-disk config aligned with the documented product defaults so
# image behavior is obvious during debugging and CI review.
mkdir -p /etc/sddm.conf.d
cat > /etc/sddm.conf.d/10-display-server.conf <<'EOF'
[General]
DisplayServer=wayland

[Wayland]
SessionDir=/usr/share/wayland-sessions
CompositorCommand=kwin_wayland --no-global-shortcuts --no-lockscreen --locale1
EOF


