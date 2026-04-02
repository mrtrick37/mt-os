#!/bin/bash

set -euo pipefail

# ── Locale filtering ──────────────────────────────────────────────────────────
# Strip non-English locale data from every subsequent RPM install.
# Saves 100–300 MB across the full package set with no functional loss
# on an English workstation.
echo '%_install_langs en_US' >> /etc/rpm/macros

### Install Docker for container operations
dnf5 install -y docker

# Add rpmfusion free and nonfree repositories for Fedora 43
dnf5 install -y https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-43.noarch.rpm || true
dnf5 install -y https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-43.noarch.rpm || true

# ── Multimedia baseline ───────────────────────────────────────────────────────
# Install a full system codec stack so common local playback, browser media,
# and creator workflows work without extra setup.  RPM Fusion provides the
# patent-encumbered pieces Fedora does not ship by default.
dnf5 install -y --skip-unavailable \
    ffmpeg \
    ffmpegthumbnailer \
    gstreamer1-plugin-openh264 \
    gstreamer1-plugins-bad-freeworld \
    gstreamer1-plugins-ugly \
    gstreamer1-libav \
    mozilla-openh264 \
    mpv

# Install all required packages
dnf5 install -y --skip-unavailable \
    p7zip \
    p7zip-plugins \
    qemu-char-spice \
    qemu-device-display-virtio-gpu \
    qemu-device-display-virtio-vga \
    qemu-device-usb-redirect \
    qemu-img \
    qemu-system-x86-core \
    util-linux-script \
    tmux \
    gh \
    fwupd

## Gaming tweaks — Bazzite-style
# Install gamescope from Fedora BEFORE enabling Bazzite COPR.
# Bazzite ships a patched gamescope; using the Fedora package avoids surprises.
dnf5 install -y gamescope

# Enable COPRs for gaming packages
dnf5 copr enable -y ublue-os/bazzite
dnf5 copr enable -y ublue-os/bazzite-multilib
dnf5 copr enable -y ublue-os/staging
dnf5 copr enable -y ublue-os/packages
dnf5 copr enable -y ublue-os/obs-vkcapture
dnf5 copr enable -y ycollet/audinux

# negativo17 Steam repo — --overwrite for idempotency (CI caches base layers)
dnf5 config-manager addrepo --overwrite --from-repofile=https://negativo17.org/repos/fedora-steam.repo

# Gaming packages
# libde265.i686 is excluded: it's an HEVC decoder pulled in transitively by Steam's
# 32-bit deps, but it's frequently unavailable on Fedora mirrors and is not needed.
dnf5 install -y --skip-unavailable --exclude=libde265.i686 \
    gamescope-shaders \
    umu-launcher \
    mangohud.x86_64 \
    mangohud.i686 \
    vkBasalt.x86_64 \
    vkBasalt.i686 \
    libFAudio.x86_64 \
    libFAudio.i686 \
    libobs_vkcapture.x86_64 \
    libobs_glcapture.x86_64 \
    libobs_vkcapture.i686 \
    libobs_glcapture.i686 \
    xrandr \
    evtest \
    xdg-user-dirs \
    xdg-terminal-exec \
    steam \
    lutris \
    gamemode \
    gamemode.i686 \
    libXScrnSaver \
    libXScrnSaver.i686 \
    libxcb.i686 \
    libatomic \
    libatomic.i686 \
    mesa-libGL.i686 \
    mesa-dri-drivers.i686 \
    nss \
    nss.i686

# KDE-specific gaming integrations
dnf5 install -y \
    kdeplasma-addons \
    rom-properties-kf6 \
    input-remapper

is_enabled() {
    case "${1,,}" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

# ── system76-scheduler ────────────────────────────────────────────────────────
# Dynamically adjusts CFS nice values and I/O priority based on which window
# is focused and whether a game is running.  Gives a noticeable responsiveness
# boost during gaming without requiring per-app configuration.
if dnf5 repoquery --available system76-scheduler 2>/dev/null | grep -q .; then
  dnf5 install -y --skip-unavailable system76-scheduler || true
  rpm -q system76-scheduler >/dev/null 2>&1 && \
    systemctl enable com.system76.Scheduler 2>/dev/null || true
else
  echo "system76-scheduler is unavailable in configured repos; skipping."
fi

# ── ananicy-cpp process priority rules ───────────────────────────────────────
# Applies static per-process CPU/I/O priorities (browser, game launchers,
# compilers, etc.) to smooth desktop responsiveness under mixed load.
if is_enabled "${ENABLE_ANANICY:-1}"; then
    if dnf5 repoquery --available ananicy-cpp 2>/dev/null | grep -q .; then
        dnf5 install -y --skip-unavailable \
                ananicy-cpp \
                ananicy-cpp-rules \
                ananicy-cpp-rules-git || true
        rpm -q ananicy-cpp >/dev/null 2>&1 && \
            systemctl enable ananicy-cpp.service 2>/dev/null || true
    else
        echo "ananicy-cpp is unavailable in configured repos; skipping."
    fi
else
    echo "ENABLE_ANANICY is off; skipping ananicy-cpp install."
fi

# Disable COPRs so they don't persist in the final image
dnf5 copr disable -y ublue-os/bazzite
dnf5 copr disable -y ublue-os/bazzite-multilib
dnf5 copr disable -y ublue-os/staging
dnf5 copr disable -y ublue-os/packages
dnf5 copr disable -y ublue-os/obs-vkcapture
dnf5 copr disable -y ycollet/audinux
# Disable negativo17 Steam repo so it doesn't leak alternate NVIDIA stacks.
dnf5 config-manager setopt fedora-steam.enabled=0 || true
sed -i "s/enabled=.*/enabled=0/g" /etc/yum.repos.d/fedora-steam.repo 2>/dev/null || true

### GPU drivers


# ── AMD ───────────────────────────────────────────────────────────────────────
# amdgpu is in the CachyOS kernel; RADV (Vulkan) comes from mesa (Fedora repos).
# linux-firmware provides the GPU firmware blobs that amdgpu loads at runtime —
# without them the driver falls back to basic/non-accelerated mode.
# libva-mesa-driver/mesa-vdpau-drivers provide AMD decode backends.
# intel-media-driver/libva-intel-driver cover newer + older Intel iGPUs.
# nvidia-vaapi-driver enables VA-API translation on supported NVIDIA systems.
dnf5 install -y --skip-unavailable \
    linux-firmware \
    libva-utils \
    mesa-va-drivers \
    mesa-vdpau-drivers \
    radeontop
dnf5 install -y libclc

# Brave Browser — replaces Firefox
dnf5 remove -y firefox || true
# On ostree/bootc-style roots, /opt is often a symlink to /var/opt.
# Ensure the symlink target exists before installing RPMs that place files in /opt.
if [ -L /opt ]; then
    opt_target="$(readlink /opt || true)"
    if [ "${opt_target}" = "var/opt" ] || [ "${opt_target}" = "/var/opt" ]; then
        mkdir -p /var/opt
    fi
fi
dnf5 config-manager addrepo --overwrite --from-repofile=https://brave-browser-rpm-release.s3.brave.com/brave-browser.repo
dnf5 install -y brave-browser
sed -i "s/enabled=.*/enabled=0/g" /etc/yum.repos.d/brave-browser.repo
# Set Brave as the default browser for all users
update-alternatives --set x-www-browser /usr/bin/brave-browser || true
xdg-settings set default-web-browser brave-browser.desktop || true

# Visual Studio Code (repo added but disabled by default)
tee /etc/yum.repos.d/vscode.repo <<'REPOEOF'
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
REPOEOF
sed -i "s/enabled=.*/enabled=0/g" /etc/yum.repos.d/vscode.repo
dnf5 -y install --enablerepo=code code

# Install Claude Code VS Code extension into /etc/skel so every new user gets
# it pre-populated in ~/.vscode/extensions/ — the location VS Code checks by
# default. Downloading the VSIX directly avoids running Electron headlessly in
# the container build, which fails without a display even with --no-sandbox.
CLAUDE_CODE_VER=$(curl -fsSL -X POST \
    "https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json;api-version=3.0-preview.1" \
    -d '{"filters":[{"criteria":[{"filterType":7,"value":"anthropic.claude-code"}]}],"flags":529}' \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['results'][0]['extensions'][0]['versions'][0]['version'])")
if [[ -z "${CLAUDE_CODE_VER}" || ! "${CLAUDE_CODE_VER}" =~ ^[0-9]+(\.[0-9]+){1,3}([-.][0-9A-Za-z]+)?$ ]]; then
    echo "ERROR: Could not resolve a valid Claude Code extension version. Got: '${CLAUDE_CODE_VER}'" >&2
    exit 1
fi
echo "Installing Claude Code extension ${CLAUDE_CODE_VER}"
curl -fL --retry 5 --retry-delay 2 --retry-all-errors \
    -H "User-Agent: kyth-image-build/1.0" \
    -H "Accept: application/octet-stream" \
    "https://marketplace.visualstudio.com/_apis/public/gallery/publishers/anthropic/vsextensions/claude-code/${CLAUDE_CODE_VER}/vspackage" \
    -o /tmp/claude-code.vsix
python3 - <<'PY'
import zipfile
import pathlib
import gzip
import sys

vsix = pathlib.Path('/tmp/claude-code.vsix')
if not vsix.exists() or vsix.stat().st_size == 0:
    print("ERROR: Claude Code VSIX download is missing or empty.", file=sys.stderr)
    sys.exit(1)

vsix_bytes = vsix.read_bytes()

# Some CDN paths return the VSIX payload gzip-wrapped.
if not zipfile.is_zipfile(vsix):
    if vsix_bytes.startswith(b"\x1f\x8b"):
        try:
            decompressed = gzip.decompress(vsix_bytes)
        except Exception as exc:
            print(f"ERROR: Failed to gunzip Claude Code artifact: {exc}", file=sys.stderr)
            sys.exit(1)
        if decompressed.startswith(b"PK\x03\x04"):
            vsix.write_bytes(decompressed)
        else:
            sample = decompressed[:240].decode("utf-8", errors="replace").replace("\n", " ")
            print("ERROR: Gzip payload is not a ZIP/VSIX.", file=sys.stderr)
            print(f"First bytes after gunzip: {sample}", file=sys.stderr)
            sys.exit(1)
    else:
        sample = vsix_bytes[:240].decode("utf-8", errors="replace").replace("\n", " ")
        print("ERROR: Downloaded Claude Code artifact is not a ZIP/VSIX.", file=sys.stderr)
        print(f"First bytes: {sample}", file=sys.stderr)
        sys.exit(1)

if not zipfile.is_zipfile(vsix):
    print("ERROR: Claude Code artifact still is not a valid ZIP after normalization.", file=sys.stderr)
    sys.exit(1)
PY
mkdir -p /etc/skel/.vscode/extensions
python3 -c "
import zipfile
with zipfile.ZipFile('/tmp/claude-code.vsix', 'r') as z:
    for member in z.namelist():
        if member.startswith('extension/'):
            z.extract(member, '/tmp/claude-code-ext/')
"
mv /tmp/claude-code-ext/extension \
    "/etc/skel/.vscode/extensions/anthropic.claude-code-${CLAUDE_CODE_VER}"
rm -rf /tmp/claude-code.vsix /tmp/claude-code-ext

# ── NVIDIA driver ─────────────────────────────────────────────────────────────
# The NVIDIA kernel module must be baked into /usr/lib/modules/ at image build
# time — bootc/ostree roots are read-only at runtime so modules cannot be
# compiled or installed post-boot.  kernel-cachyos-devel is installed in
# build_base while the CachyOS COPR is active, so the headers are present here.
# On AMD/Intel systems these packages are inert: the nvidia module exists in the
# image but udev never loads it without NVIDIA hardware present.
# If another repo pulled in a different NVIDIA family (for example negativo17),
# remove its shared-common package to avoid file conflicts with RPM Fusion.
dnf5 remove -y nvidia-kmod-common || true
# Keep this install constrained to Fedora + RPM Fusion repos so solver doesn't
# mix incompatible NVIDIA package streams from third-party repos.
# Exclude nvidia-kmod-common: RPM Fusion transiently ships it at a newer driver
# version (595.x) than xorg-x11-drv-nvidia (580.x).  Both packages provide
# /usr/bin/nvidia-bug-report.sh causing a file conflict in the same transaction.
# At 580.x the driver package itself still contains those shared files, so the
# exclude is safe.  Remove this exclusion once RPM Fusion versions converge.
dnf5 install -y --skip-unavailable --allowerasing \
    --disablerepo='*' \
    --enablerepo='fedora*' \
    --enablerepo='updates*' \
    --enablerepo='rpmfusion*' \
    --exclude=nvidia-kmod-common \
    akmods \
    akmod-nvidia \
    xorg-x11-drv-nvidia \
    xorg-x11-drv-nvidia-cuda \
    xorg-x11-drv-nvidia-libs \
    xorg-x11-drv-nvidia-libs.i686 \
    nvidia-vaapi-driver

# Warn when nvidia-kmod-common and xorg-x11-drv-nvidia ship the same version —
# at that point the --exclude=nvidia-kmod-common above can be dropped.
_drv_ver=$(rpm -q --qf '%{version}' xorg-x11-drv-nvidia 2>/dev/null || true)
_common_ver=$(dnf5 repoquery --available --disablerepo='*' \
    --enablerepo='fedora*' --enablerepo='updates*' --enablerepo='rpmfusion*' \
    --qf '%{version}' nvidia-kmod-common 2>/dev/null | sort -V | tail -1 || true)
if [[ -n "${_drv_ver}" && -n "${_common_ver}" && "${_drv_ver}" == "${_common_ver}" ]]; then
    echo "INFO: xorg-x11-drv-nvidia and nvidia-kmod-common are both at ${_drv_ver}." \
         "The --exclude=nvidia-kmod-common workaround in packages.sh can now be removed."
fi
unset _drv_ver _common_ver

# Compile the NVIDIA kernel module against the installed CachyOS kernel.
# akmods writes the .ko files to /usr/lib/modules/<kver>/extra/.
NVIDIA_KVER=$(basename "$(echo /usr/lib/modules/*cachyos*)")
echo "Building NVIDIA module for kernel ${NVIDIA_KVER}"
akmods --force --kernels "${NVIDIA_KVER}"
# Fail loudly if the module was not produced — a silent miss here means NVIDIA
# users get a black screen with no obvious cause.
modinfo -k "${NVIDIA_KVER}" nvidia > /dev/null \
    || { echo "ERROR: NVIDIA module failed to build for ${NVIDIA_KVER}"; exit 1; }

# ── Kyth Helper app ───────────────────────────────────────────────────────────
# PyQt6 helper + branch switcher.  Autostarts on first login via skel.
dnf5 install -y python3-pyqt6

# Plymouth deps (theme install is in branding.sh)
dnf5 install -y plymouth plymouth-plugin-script

# ── Distrobox ─────────────────────────────────────────────────────────────────
# Lets users run mutable containers (any distro) alongside the immutable base OS.
# Essential on atomic systems for one-off package installs without rpm-ostree.
dnf5 install -y distrobox

# ── Display / resolution auto-detection ──────────────────────────────────────
# spice-vdagent: in QEMU/KVM VMs this daemon handles dynamic resolution changes
# via the SPICE protocol, so the VM display auto-resizes to the window size.
# On bare metal it is a no-op.  kscreen-doctor (from kscreen) is the KDE CLI
# for querying and configuring outputs; used by the first-login script below.
dnf5 install -y spice-vdagent virt-viewer kscreen
# spice-vdagentd is socket/udev-activated — no systemctl enable needed.

# Homebrew RPM deps
# Clean cached packages before this install: libxcrypt-compat has been showing
# corrupt RPM files in the persistent DNF cache. Remove once mirror stabilises.
dnf5 clean packages
dnf5 install -y --nogpgcheck gcc glibc-devel libxcrypt-compat patch ruby
