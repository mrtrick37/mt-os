# Allow build scripts to be referenced without being copied into the final image
FROM scratch AS ctx
COPY build_files /

# Base Image
FROM localhost/kyth-base:stable

# Override upstream OCI labels so downstream tooling (lorax/bootc) sees Kyth product metadata
LABEL org.opencontainers.image.title="Kyth"
LABEL org.opencontainers.image.version="43"
LABEL org.opencontainers.image.description="Kyth — atomic gaming and dev workstation built on Fedora Kinoite"
LABEL org.opencontainers.image.licenses="Apache-2.0"
LABEL org.opencontainers.image.source="https://github.com/mrtrick37/kyth"
LABEL org.opencontainers.image.documentation="https://github.com/mrtrick37/kyth"
LABEL org.osbuild.product="Kyth"
LABEL org.osbuild.version="43"
LABEL org.osbuild.branding.release="Kyth 43"

### MODIFICATIONS
ARG ENABLE_ANANICY=1
ARG ENABLE_SCX=1

# Layer 1: All RPM packages, repos, and dnf upgrade (~2-3 GB).
# Re-downloaded only when packages are added/removed or upstream RPMs update.
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    ENABLE_ANANICY=${ENABLE_ANANICY} /ctx/scripts/packages.sh

# Layer 2: Third-party binaries — topgrade, winetricks, SCX schedulers, Homebrew (~400 MB).
# Re-downloaded when upstream projects cut new releases.
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=tmpfs,dst=/tmp \
    ENABLE_SCX=${ENABLE_SCX} /ctx/scripts/thirdparty.sh

# Layer 3: System configuration — sysctl, audio, gaming tuning, env vars (~few KB).
# Re-downloaded only when tuning values change.
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/scripts/sysconfig.sh

# Layer 4: Branding, theming, helper app, Plymouth (~10 MB).
# Re-downloaded on Kyth version bumps or welcome app updates.
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/scripts/branding.sh

# Layer 5: GE-Proton (~700 MB). Only re-downloaded when GE_PROTON_VER is bumped.
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/scripts/ge-proton.sh

# Layer 6: Mesa-git (~300-500 MB). Re-downloaded on daily CI builds.
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/scripts/mesa-git.sh
