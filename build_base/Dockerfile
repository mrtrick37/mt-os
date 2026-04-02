# Pull the upstream Fedora bootc base and apply KythOS branding.
# Build with: docker build -t localhost/kyth-base:stable build_base/
# Override the base via: docker build --build-arg BASE_IMAGE=ghcr.io/ublue-os/kinoite-main:43 build_base/
ARG BASE_IMAGE=ghcr.io/ublue-os/kinoite-main:43
FROM ${BASE_IMAGE}

# Use a bind-mount so the script is never written into any image layer
RUN --mount=type=bind,source=build.sh,target=/run/build.sh \
    bash /run/build.sh
