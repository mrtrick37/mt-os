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

# Layer 1: All packages, kernel, system config, branding.
# Large but stable — only re-downloaded when packages or config change.
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    ENABLE_ANANICY=${ENABLE_ANANICY} ENABLE_SCX=${ENABLE_SCX} /ctx/build.sh

# Layer 2: GE-Proton (~700 MB). Only re-downloaded when GE_PROTON_VER is bumped.
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/scripts/ge-proton.sh

# Layer 3: Mesa-git (~300-500 MB). Re-downloaded on daily CI builds, kept small
# so bootc updates pull this layer instead of the full 3+ GB base layer.
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/scripts/mesa-git.sh
