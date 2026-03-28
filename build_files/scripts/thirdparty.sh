#!/bin/bash

set -euo pipefail

is_enabled() {
    case "${1,,}" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

# ── topgrade ─────────────────────────────────────────────────────────────────
# Not in Fedora 43 repos — install pre-built binary from GitHub releases.
# Uses the musl-linked build for maximum compatibility across libc versions.
TOPGRADE_REPO_API="https://api.github.com/repos/topgrade-rs/topgrade/releases/latest"
TMPDIR_TG=$(mktemp -d)
release_json="${TMPDIR_TG}/release.json"
if curl -fsSL "${TOPGRADE_REPO_API}" -o "${release_json}" 2>/dev/null; then
    TOPGRADE_URL=$(
        grep -oP 'https://[^"]+\.tar\.(gz|zst)' "${release_json}" \
        | grep -i 'x86.64\|x86_64\|amd64' \
        | grep -i 'musl\|linux' \
        | grep -iv 'source' \
        | head -n1
    ) || true
    if [[ -n "${TOPGRADE_URL}" ]]; then
        TOPGRADE_TARBALL=$(basename "${TOPGRADE_URL}")
        curl -fsSL "${TOPGRADE_URL}" -o "${TMPDIR_TG}/${TOPGRADE_TARBALL}"
        tar -xf "${TMPDIR_TG}/${TOPGRADE_TARBALL}" -C "${TMPDIR_TG}/"
        find "${TMPDIR_TG}" -name 'topgrade' -type f \
            -exec install -m 0755 {} /usr/bin/topgrade \;
        echo "topgrade installed: $(topgrade --version 2>/dev/null || echo 'unknown version')"
    else
        echo "topgrade: no musl x86_64 tarball found in release assets; skipping."
    fi
else
    echo "topgrade: failed to fetch release info from GitHub; skipping."
fi
rm -rf "${TMPDIR_TG}"

# Download winetricks from upstream (package version is often outdated)
# Pin to the signed release commit so the build does not trust a mutable ref
# for an executable shell script.
# /usr/local symlinks to /var/usrlocal — ensure the target dir exists
WINETRICKS_VER="20260125"
WINETRICKS_COMMIT="b76e1ee"
mkdir -p /usr/local/bin
curl -fsSL "https://raw.githubusercontent.com/Winetricks/winetricks/${WINETRICKS_COMMIT}/src/winetricks" \
    -o /tmp/winetricks
# Sanity-check: must be a shell script before installing
head -1 /tmp/winetricks | grep -q '^#!' || { echo "winetricks download looks invalid"; exit 1; }
install -m 0755 /tmp/winetricks /usr/local/bin/winetricks
rm -f /tmp/winetricks

# ── scx userspace schedulers ──────────────────────────────────────────────────
# sched-ext (scx) is a BPF-based scheduler framework in the CachyOS kernel.
# scx_lavd is optimised for interactive + gaming — it prioritises latency-
# sensitive threads (audio, input, render) while keeping throughput tasks warm.
#
# We pull pre-built binaries directly from the upstream GitHub release rather
# than relying on a COPR that may not have a Fedora 43 build available.
if is_enabled "${ENABLE_SCX:-1}"; then
    SCX_REPO_API="https://api.github.com/repos/sched-ext/scx/releases/latest"
    TMPDIR_SCX=$(mktemp -d)

    release_json="${TMPDIR_SCX}/release.json"
    if curl -fsSL "${SCX_REPO_API}" -o "${release_json}" 2>/dev/null; then
        # Find a Linux x86_64 binary tarball in the release assets.
        # Accept .tar.gz and .tar.zst (SCX releases have used both formats).
        SCX_TARBALL_URL=$(
            grep -oP 'https://[^"]+\.tar\.(gz|zst)' "${release_json}" \
            | grep -i 'x86.64\|x86_64\|amd64' \
            | grep -iv 'source' \
            | head -n1
        ) || true

        if [[ -n "${SCX_TARBALL_URL}" ]]; then
            SCX_TARBALL=$(basename "${SCX_TARBALL_URL}")
            echo "scx: downloading ${SCX_TARBALL}"
            curl -fsSL "${SCX_TARBALL_URL}" -o "${TMPDIR_SCX}/${SCX_TARBALL}"
            tar -xf "${TMPDIR_SCX}/${SCX_TARBALL}" -C "${TMPDIR_SCX}/"

            # Install scx_* scheduler binaries and scxd
            find "${TMPDIR_SCX}" \( -name 'scx_*' -o -name 'scxd' \) -type f \
                -exec install -m 0755 {} /usr/bin/ \;

            if command -v scxd >/dev/null 2>&1; then
                # Provide scxd.service — not present without the RPM
                mkdir -p /usr/lib/systemd/system
                cat > /usr/lib/systemd/system/scxd.service <<'SCXSVCEOF'
[Unit]
Description=sched-ext userspace scheduler daemon
Documentation=https://github.com/sched-ext/scx
After=basic.target

[Service]
Type=simple
EnvironmentFile=-/etc/scx/config
ExecStart=/usr/bin/scxd
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SCXSVCEOF

                # Pick the best available scheduler: lavd > rusty > bpfland
                SCX_SCHEDULER=""
                for sched in scx_lavd scx_rusty scx_bpfland; do
                    if command -v "$sched" >/dev/null 2>&1; then
                        SCX_SCHEDULER="$sched"
                        break
                    fi
                done

                if [[ -n "$SCX_SCHEDULER" ]]; then
                    mkdir -p /etc/scx
                    cat > /etc/scx/config <<SCXEOF
SCX_SCHEDULER=${SCX_SCHEDULER}
SCX_FLAGS=--auto-mode
SCXEOF
                    systemctl enable scxd.service 2>/dev/null || true
                    echo "scx: enabled ${SCX_SCHEDULER}"
                else
                    echo "scx: no scheduler binaries found in archive"
                fi
            else
                echo "scx: scxd not found after extraction"
            fi
        else
            echo "scx: no x86_64 tarball found in release assets; skipping."
        fi
    else
        echo "scx: failed to fetch release info from GitHub; skipping."
    fi

    rm -rf "${TMPDIR_SCX}"
else
    echo "ENABLE_SCX is off; skipping scx scheduler install."
fi

# Homebrew — system-wide install to /home/linuxbrew (= /var/home/linuxbrew at runtime)
# Owned by a dedicated non-root 'linuxbrew' system user so topgrade does not invoke
# brew via sudo (which brew refuses). Wheel group gets write access so any wheel
# user can install/update formulae without privilege escalation.
#
# Pinned to a release tag so the thirdparty layer hash stays stable between daily
# CI builds. Bump HOMEBREW_TAG when you want to ship a newer Homebrew version.
HOMEBREW_TAG="5.1.1"
useradd -r -d /home/linuxbrew -M -s /sbin/nologin linuxbrew
git clone --depth 1 --branch "${HOMEBREW_TAG}" \
    https://github.com/Homebrew/brew /home/linuxbrew/.linuxbrew \
    || { echo "ERROR: Homebrew git clone failed"; exit 1; }
[ -f /home/linuxbrew/.linuxbrew/bin/brew ] \
    || { echo "ERROR: Homebrew clone appears empty"; exit 1; }
chown -R linuxbrew:wheel /home/linuxbrew
chmod -R g+w /home/linuxbrew
find /home/linuxbrew -type d -exec chmod g+s {} \;
# Add brew to PATH for all login shells
cat > /etc/profile.d/homebrew.sh <<'BREWEOF'
if [ -d /home/linuxbrew/.linuxbrew ]; then
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
fi
BREWEOF
chmod +x /etc/profile.d/homebrew.sh
