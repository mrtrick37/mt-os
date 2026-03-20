# Rebase to a different Kyth image.
# Usage:
#   ujust rebase kyth:stable
#   ujust rebase kyth:testing
#   ujust rebase kyth:latest
#   ujust rebase                   (defaults to kyth:latest)
#
# Short form "kyth:<tag>" is expanded to ghcr.io/mrtrick37/kyth:<tag>.
# A full image reference (containing '/') is used as-is.

[group('Kyth')]
rebase image_ref="kyth:latest":
    #!/usr/bin/env bash
    set -euo pipefail
    ref="{{ image_ref }}"
    # Expand short form: "kyth:tag" or "kyth" → "ghcr.io/mrtrick37/kyth:tag"
    if [[ "$ref" != *"/"* ]]; then
        ref="ghcr.io/mrtrick37/${ref}"
    fi
    # Default to :latest if no tag was given
    if [[ "$ref" != *":"* ]]; then
        ref="${ref}:latest"
    fi
    echo "Rebasing to: ${ref}"
    echo "This will take effect on next reboot."
    sudo bootc switch "${ref}"

# Run a game or app with the temporary performance profile wrapper.
[group('Kyth')]
game-performance +args:
    #!/usr/bin/env bash
    set -euo pipefail
    /usr/bin/game-performance {{ args }}

# Run an OpenGL app through Zink.
[group('Kyth')]
zink-run +args:
    #!/usr/bin/env bash
    set -euo pipefail
    /usr/bin/zink-run {{ args }}

# Print a short Kyth system/kernel tuning summary.
[group('Kyth')]
kerver:
    #!/usr/bin/env bash
    set -euo pipefail
    /usr/bin/kyth-kerver

# Print a paste-friendly system support snapshot.
[group('Kyth')]
device-info:
    #!/usr/bin/env bash
    set -euo pipefail
    /usr/bin/kyth-device-info

# Install LACT from Flathub on an immutable system.
[group('Kyth')]
install-lact:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! command -v flatpak >/dev/null 2>&1; then
        echo "flatpak is not available on this system." >&2
        exit 1
    fi
    flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
    flatpak install -y flathub io.github.ilya_zlobintsev.LACT
    echo
    echo "LACT installed."
    echo "Launch it from the app launcher."
    echo "If you want overclocking/undervolting on AMD, review the official LACT Atomic guidance first."

# Layer input-remapper onto the next deployment.
[group('Kyth')]
install-input-remapper:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! command -v rpm-ostree >/dev/null 2>&1; then
        echo "rpm-ostree is not available on this system." >&2
        exit 1
    fi
    echo "Layering input-remapper into the next deployment..."
    sudo rpm-ostree install input-remapper
    echo
    echo "input-remapper will be available after reboot."

# Check for and apply firmware updates via fwupd.
[group('Kyth')]
firmware-update:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Refreshing firmware metadata..."
    fwupdmgr refresh --force
    echo
    echo "Checking for firmware updates..."
    fwupdmgr get-updates || true
    echo
    echo "Applying available firmware updates..."
    fwupdmgr update
