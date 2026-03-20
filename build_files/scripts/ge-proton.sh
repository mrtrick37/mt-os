#!/bin/bash
set -euo pipefail

# ── GE-Proton ────────────────────────────────────────────────────────────────
# Installed system-wide so Steam picks it up for all users without manual setup.
# Steam looks in /usr/share/steam/compatibilitytools.d/ in addition to ~/.steam.
# This lives in its own image layer so GE-Proton refreshes only re-download
# this layer (~700 MB), not the full 3+ GB package layer.
GE_PROTON_REPO_API="https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases"
GE_PROTON_VER="${GE_PROTON_VER:-}"
TMPDIR_GE=$(mktemp -d)
trap 'rm -rf "${TMPDIR_GE}"' EXIT

if [[ -n "${GE_PROTON_VER}" ]]; then
    release_api="${GE_PROTON_REPO_API}/tags/${GE_PROTON_VER}"
else
    release_api="${GE_PROTON_REPO_API}/latest"
fi

release_json="${TMPDIR_GE}/release.json"
curl -fsSL "${release_api}" -o "${release_json}"

GE_PROTON_TARBALL_URL=$(
    grep -o 'https://[^"]*\.tar\.gz' "${release_json}" | head -n1
)
GE_PROTON_SHA512_URL=$(
    grep -o 'https://[^"]*\.sha512sum' "${release_json}" | head -n1
)

if [[ -z "${GE_PROTON_TARBALL_URL}" || -z "${GE_PROTON_SHA512_URL}" ]]; then
    echo "Failed to locate GE-Proton release assets from ${release_api}" >&2
    exit 1
fi

GE_PROTON_TARBALL=$(basename "${GE_PROTON_TARBALL_URL}")
GE_PROTON_SHA512=$(basename "${GE_PROTON_SHA512_URL}")

mkdir -p /usr/share/steam/compatibilitytools.d
curl -fsSL "${GE_PROTON_TARBALL_URL}" \
    -o "${TMPDIR_GE}/${GE_PROTON_TARBALL}"
curl -fsSL "${GE_PROTON_SHA512_URL}" \
    -o "${TMPDIR_GE}/${GE_PROTON_SHA512}"

(
    cd "${TMPDIR_GE}"
    sha512sum -c "${GE_PROTON_SHA512}"
)

tar -xzf "${TMPDIR_GE}/${GE_PROTON_TARBALL}" -C /usr/share/steam/compatibilitytools.d/
