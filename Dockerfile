# Allow build scripts to be referenced without being copied into the final image
FROM scratch AS ctx
COPY build_files /

# Base Image
FROM localhost/kyth-base:stable

# Override upstream OCI labels so downstream tooling (lorax/bootc) sees KythOS product metadata
LABEL org.opencontainers.image.title="KythOS"
LABEL org.opencontainers.image.version="44"
LABEL org.opencontainers.image.description="KythOS — atomic gaming and dev workstation built on Fedora Kinoite"
LABEL org.opencontainers.image.licenses="Apache-2.0"
LABEL org.opencontainers.image.source="https://github.com/mrtrick37/kyth"
LABEL org.opencontainers.image.documentation="https://github.com/mrtrick37/kyth"
LABEL org.osbuild.product="KythOS"
LABEL org.osbuild.version="44"
LABEL org.osbuild.branding.release="KythOS 44"

### MODIFICATIONS
ARG ENABLE_ANANICY=1
ARG ENABLE_SCX=1

# Layer 1: All RPM package installs (~2-3 GB).
# Stable — only re-downloaded when packages are explicitly added/removed.
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    ENABLE_ANANICY=${ENABLE_ANANICY} /ctx/scripts/packages.sh

# Layer 2: Upstream RPM upgrades (~50-500 MB daily delta).
# Isolated so daily package updates don't invalidate the full install layer above.
RUN --mount=type=cache,dst=/var/cache \
    --mount=type=tmpfs,dst=/tmp \
    set -euo pipefail; \
    _drv_ver=$(rpm -q --qf '%{version}' xorg-x11-drv-nvidia 2>/dev/null || true); \
    _common_ver=$(dnf5 repoquery --available --qf '%{version}' nvidia-kmod-common 2>/dev/null | sort -V | tail -1 || true); \
    if [ -n "${_drv_ver}" ] && [ -n "${_common_ver}" ] && [ "${_drv_ver}" = "${_common_ver}" ]; then \
        echo "NVIDIA packages consistent (${_drv_ver}); upgrading freely."; \
        dnf5 upgrade -y --exclude='kernel*' --exclude='gamescope*' \
            --exclude='gstreamer1-plugins-bad' \
            --exclude='gstreamer1-plugins-bad.i686'; \
    else \
        echo "NVIDIA version mismatch (installed xorg-x11-drv-nvidia=${_drv_ver}, available nvidia-kmod-common=${_common_ver}); holding NVIDIA packages."; \
        dnf5 upgrade -y --exclude='kernel*' --exclude='gamescope*' \
            --exclude='gstreamer1-plugins-bad' \
            --exclude='gstreamer1-plugins-bad.i686' \
            --exclude='nvidia-kmod-common' \
            --exclude='akmod-nvidia*' \
            --exclude='xorg-x11-drv-nvidia*'; \
    fi && \
    dnf5 upgrade -y libdrm && \
    dnf5 clean all

# Layer 3: Third-party binaries — topgrade, winetricks, SCX schedulers, Homebrew (~400 MB).
# Stable — re-downloaded only when upstream projects cut new releases or pins are bumped.
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=tmpfs,dst=/tmp \
    ENABLE_SCX=${ENABLE_SCX} /ctx/scripts/thirdparty.sh

# Layer 4: System configuration — sysctl, audio, gaming tuning, env vars (~few KB).
# Re-downloaded only when tuning values change.
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/scripts/sysconfig.sh

# Layer 5: Branding, theming, helper app, Plymouth (~10 MB).
# Re-downloaded on KythOS version bumps or welcome app updates.
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/scripts/branding.sh

# Layer 6: GE-Proton (~700 MB). Only re-downloaded when GE_PROTON_VER is bumped.
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/scripts/ge-proton.sh

# Layer 7: Mesa-git (~300-500 MB). Re-downloaded on daily CI builds.
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/scripts/mesa-git.sh
