#!/bin/bash
set -euo pipefail

# ── GE-Proton ────────────────────────────────────────────────────────────────
# Installed system-wide so Steam picks it up for all users without manual setup.
# Steam looks in /usr/share/steam/compatibilitytools.d/ in addition to ~/.steam.
# This lives in its own image layer so bumping GE_PROTON_VER only re-downloads
# this layer (~700 MB), not the full 3+ GB package layer.
# 2026-03-19: GitHub shows a GE-Proton10-33 release page, but its asset URLs
# currently 404. Pin to the latest release with published tarball assets.
GE_PROTON_VER="GE-Proton10-32"
GE_PROTON_BASE_URL="https://github.com/GloriousEggroll/proton-ge-custom/releases/download/${GE_PROTON_VER}"
GE_PROTON_TARBALL="${GE_PROTON_VER}.tar.gz"
GE_PROTON_SHA512="${GE_PROTON_TARBALL}.sha512sum"
TMPDIR_GE=$(mktemp -d)
trap 'rm -rf "${TMPDIR_GE}"' EXIT

mkdir -p /usr/share/steam/compatibilitytools.d
curl -fsSL "${GE_PROTON_BASE_URL}/${GE_PROTON_TARBALL}" \
    -o "${TMPDIR_GE}/${GE_PROTON_TARBALL}"
curl -fsSL "${GE_PROTON_BASE_URL}/${GE_PROTON_SHA512}" \
    -o "${TMPDIR_GE}/${GE_PROTON_SHA512}"

(
    cd "${TMPDIR_GE}"
    sha512sum -c "${GE_PROTON_SHA512}"
)

tar -xzf "${TMPDIR_GE}/${GE_PROTON_TARBALL}" -C /usr/share/steam/compatibilitytools.d/
