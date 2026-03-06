export image_name := env("IMAGE_NAME", "mt-os") # output image name, usually same as repo name, change as needed
export default_tag := env("DEFAULT_TAG", "latest")
export bib_image := env("BIB_IMAGE", "quay.io/centos-bootc/bootc-image-builder:latest")

alias build-vm := build-qcow2
alias rebuild-vm := rebuild-qcow2
alias run-vm := run-vm-qcow2

[private]
default:
    @just --list

# Check Just Syntax
[group('Just')]
check:
    #!/usr/bin/bash
    find . -type f -name "*.just" | while read -r file; do
    	echo "Checking syntax: $file"
    	just --unstable --fmt --check -f $file
    done
    echo "Checking syntax: Justfile"
    just --unstable --fmt --check -f Justfile

# Fix Just Syntax
[group('Just')]
fix:
    #!/usr/bin/bash
    find . -type f -name "*.just" | while read -r file; do
    	echo "Checking syntax: $file"
    	just --unstable --fmt -f $file
    done
    echo "Checking syntax: Justfile"
    just --unstable --fmt -f Justfile || { exit 1; }

# Clean Repo
[group('Utility')]
clean:
    #!/usr/bin/bash
    set -eoux pipefail
    touch _build
    find *_build* -exec rm -rf {} \;
    rm -f previous.manifest.json
    rm -f changelog.md
    rm -f output.env
    rm -f output/

# Sudo Clean Repo
[group('Utility')]
[private]
sudo-clean:
    just sudoif just clean

# Safely remove local build temp dirs and fix ownership of output/
[group('Utility')]
cleanup:
    #!/usr/bin/env bash
    set -euo pipefail

    echo "This will remove any _build-bib.* directories in ${PWD} and fix ownership of output/."
    if [[ "${AUTO_CONFIRM:-}" != "true" ]]; then
        read -r -p "Proceed? [y/N]: " ans
        if [[ ! "${ans}" =~ ^[Yy]$ ]]; then
            echo "Aborted by user."; exit 1
        fi
    fi

    if ls _build-bib.* 1> /dev/null 2>&1; then
        echo "Removing _build-bib.*..."
        sudo rm -rf _build-bib.* || true
    else
        echo "No _build-bib.* directories found."
    fi

    if [ -d output ]; then
        echo "Fixing ownership of output/ to current user..."
        sudo chown -R "$(id -u):$(id -g)" output/ || true
    fi

    echo "Cleanup complete."

# sudoif bash function
[group('Utility')]
[private]
sudoif command *args:
    #!/usr/bin/bash
    function sudoif(){
        if [[ "${UID}" -eq 0 ]]; then
            "$@"
        elif [[ "$(command -v sudo)" && -n "${SSH_ASKPASS:-}" ]] && [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]; then
            /usr/bin/sudo --askpass "$@" || exit 1
        elif [[ "$(command -v sudo)" ]]; then
            /usr/bin/sudo "$@" || exit 1
        else
            exit 1
        fi
    }
    sudoif {{ command }} {{ args }}
        TMPDIR=${TMPDIR:-/var/tmp}

# This Justfile recipe builds a container image using Podman.
#
# Arguments:
#   $target_image - The tag you want to apply to the image (default: $image_name).
#   $tag - The tag for the image (default: $default_tag).
#
# The script constructs the version string using the tag and the current date.
# If the git working directory is clean, it also includes the short SHA of the current HEAD.
#
# just build $target_image $tag
#
# Example usage:
#   just build aurora lts
#
# This will build an image 'aurora:lts' with DX and GDX enabled.
#

# Build the image using the specified parameters
build $target_image=image_name $tag=default_tag:
    #!/usr/bin/env bash

    BUILD_ARGS=()
    if [[ -z "$(git status -s)" ]]; then
        BUILD_ARGS+=("--build-arg" "SHA_HEAD_SHORT=$(git rev-parse --short HEAD)")
    fi

    podman build \
        "${BUILD_ARGS[@]}" \
        --pull=newer \
        --tag "${target_image}:${tag}" \
        .

# Command: _rootful_load_image
# Description: This script checks if the current user is root or running under sudo. If not, it attempts to resolve the image tag using podman inspect.
#              If the image is found, it loads it into rootful podman. If the image is not found, it pulls it from the repository.
#
# Parameters:
#   $target_image - The name of the target image to be loaded or pulled.
#   $tag - The tag of the target image to be loaded or pulled. Default is 'default_tag'.
#
# Example usage:
#   _rootful_load_image my_image latest
#
# Steps:
# 1. Check if the script is already running as root or under sudo.
# 2. Check if target image is in the non-root podman container storage)
# 3. If the image is found, load it into rootful podman using podman scp.
# 4. If the image is not found, pull it from the remote repository into reootful podman.

_rootful_load_image $target_image=image_name $tag=default_tag:
    #!/usr/bin/bash
    set -eoux pipefail

    # Check if already running as root or under sudo
    if [[ -n "${SUDO_USER:-}" || "${UID}" -eq "0" ]]; then
        echo "Already root or running under sudo, no need to load image from user podman."
        exit 0
    fi

    # Try to resolve the image tag using podman inspect
    set +e
    resolved_tag=$(podman inspect -t image "${target_image}:${tag}" | jq -r '.[].RepoTags.[0]')
    return_code=$?
    set -e

    USER_IMG_ID=$(podman images --filter reference="${target_image}:${tag}" --format "'{{ '{{.ID}}' }}'")

    if [[ $return_code -eq 0 ]]; then
        # If the image is found, load it into rootful podman
        ID=$(just sudoif podman images --filter reference="${target_image}:${tag}" --format "'{{ '{{.ID}}' }}'")
        if [[ "$ID" != "$USER_IMG_ID" ]]; then
            # If the image ID is not found or different from user, copy the image from user podman to root podman
            COPYTMP=$(mktemp -p /var/tmp -d -t _build_podman_scp.XXXXXXXXXX)
            just sudoif TMPDIR=${COPYTMP} podman image scp ${UID}@localhost::"${target_image}:${tag}" root@localhost::"${target_image}:${tag}"
            rm -rf "${COPYTMP}"
        fi
    else
        # If the image is not found, pull it from the repository
        just sudoif podman pull "${target_image}:${tag}"
    fi

# Build a bootc bootable image using Bootc Image Builder (BIB)
# Converts a container image to a bootable image
# Parameters:
#   target_image: The name of the image to build (ex. localhost/fedora)
#   tag: The tag of the image to build (ex. latest)
#   type: The type of image to build (ex. qcow2, raw, iso)
#   config: The configuration file to use for the build (default: disk_config/disk.toml)

# Example: just _rebuild-bib localhost/fedora latest qcow2 disk_config/disk.toml
_build-bib $target_image $tag $type $config: (_rootful_load_image target_image tag)
    #!/usr/bin/env bash
    set -euo pipefail

    args="--type ${type} "
    args+="--use-librepo=True "
    args+="--rootfs=btrfs "

    # Create build temp under $TMPDIR (fallback /var/tmp) so repository root isn't filled
    TMPDIR=${TMPDIR:-/var/tmp}
    BUILDTMP=$(mktemp -p "${TMPDIR}" -d -t _build-bib.XXXXXXXXXX)
    # Ensure temporary build directory is cleaned on exit
    trap 'sudo rm -rf "${BUILDTMP}" >/dev/null 2>&1 || true' EXIT
    BUILDDIR=${PWD}

        # Allow providing the repo GPG key(s) in the workspace so dnf inside the builder
        # can access file:///etc/pki/rpm-gpg/RPM-GPG-KEY-terra43-mesa (or other keys).
        KEY_MOUNT=""
        if [[ -f "${BUILDDIR}/RPM-GPG-KEY-terra43-mesa" ]]; then
            KEY_MOUNT="-v ${BUILDDIR}/RPM-GPG-KEY-terra43-mesa:/etc/pki/rpm-gpg/RPM-GPG-KEY-terra43-mesa:ro"
        elif [[ -d "${BUILDDIR}/pki/rpm-gpg" ]]; then
            KEY_MOUNT="-v ${BUILDDIR}/pki/rpm-gpg:/etc/pki/rpm-gpg:ro"
        fi

        # Attempt to extract product metadata from the image's OCI labels and pass
        # them to bootc/lorax so lorax receives a valid product.name/product.version.
        # Provide sensible defaults so installer UI shows mt-OS even when labels
        # are missing from the base image.
        PRODUCT_NAME="mt-OS"
        PRODUCT_VERSION="43"
        set +e
        # Use podman inspect JSON and jq to avoid Justfile interpolation issues
        labels_json=$(podman inspect "${target_image}:${tag}" 2>/dev/null | jq -c '.[0].Config.Labels // {}' 2>/dev/null || true)
        set -e
        if [[ -n "${labels_json}" && "${labels_json}" != "null" ]]; then
            PRODUCT_NAME=$(echo "${labels_json}" | jq -r '."org.opencontainers.image.title" // empty' || true)
            PRODUCT_VERSION=$(echo "${labels_json}" | jq -r '."org.opencontainers.image.version" // empty' || true)
        fi
        # Do not pass --version to bootc-image-builder (it treats --version as a boolean).
        # We patch generated manifest files below to set product/version when available.

        # Enable debug logging from bootc-image-builder to surface why lorax product/version are empty
        args+="--log-level=debug "

        sudo podman run \
            --rm \
            -it \
            --privileged \
            --pull=newer \
            --net=host \
            --security-opt label=type:unconfined_t \
            $KEY_MOUNT \
            -v $(pwd)/${config}:/config.toml:ro \
            -v $BUILDTMP:/output \
            -v /var/lib/containers/storage:/var/lib/containers/storage \
            "${bib_image}" \
            ${args} \
            "${target_image}:${tag}"

    mkdir -p output
    # If bootc produced a manifest but lorax product/version are empty, patch them
    if sudo test -d "$BUILDTMP"; then
        for mf in $BUILDTMP/manifest*.json; do
            if sudo test -f "$mf"; then
                    # Run jq under sudo with variables expanded by the current shell to avoid complex shell-quoting.
                    sudo jq --arg pname "${PRODUCT_NAME}" --arg pver "${PRODUCT_VERSION}" \
                        '(.pipelines[]?.stages[]? |= ( if .type=="org.osbuild.lorax-script" then (.options.product.name = $pname) | (.options.product.version = $pver) | (.options.branding.release = ($pname + " " + $pver)) else . end ))' "$mf" > "$mf.tmp" || true
                    sudo mv -f "$mf.tmp" "$mf" || true
            fi
        done
    fi
    # Rotate previous builds: keep last two
    sudo mkdir -p output/previous-built-iso
    if sudo test -d output/previous-built-iso/1; then
        sudo rm -rf output/previous-built-iso/2 || true
        sudo mv output/previous-built-iso/1 output/previous-built-iso/2 || true
    fi
    if sudo test -d output/bootiso; then
        sudo mv output/bootiso output/previous-built-iso/1 || true
    fi

    # Move new build output into place
    sudo mv -f $BUILDTMP/* output/ || true
    # Rename standard install ISO to a consistent mt-OS filename
    if sudo test -f output/bootiso/install.iso; then
        sudo mv -f output/bootiso/install.iso output/bootiso/mt-os-installer.iso || true
    fi
    sudo rmdir $BUILDTMP || true
    sudo chown -R $USER:$USER output/

    # Print absolute path to produced ISO if present (helps CI and users find artifact)
    if sudo test -f output/bootiso/mt-os-installer.iso; then
        ISO_PATH=$(readlink -f output/bootiso/mt-os-installer.iso)
        echo "Produced ISO: ${ISO_PATH}"
    fi

# Podman builds the image from the Containerfile and creates a bootable image
# Parameters:
#   target_image: The name of the image to build (ex. localhost/fedora)
#   tag: The tag of the image to build (ex. latest)
#   type: The type of image to build (ex. qcow2, raw, iso)
#   config: The configuration file to use for the build (deafult: disk_config/disk.toml)

# Example: just _rebuild-bib localhost/fedora latest qcow2 disk_config/disk.toml
_rebuild-bib $target_image $tag $type $config: (build target_image tag) && (_build-bib target_image tag type config)

# Build a QCOW2 virtual machine image
[group('Build Virtal Machine Image')]
build-qcow2 $target_image=("localhost/" + image_name) $tag=default_tag: && (_build-bib target_image tag "qcow2" "disk_config/disk.toml")

# Build a RAW virtual machine image
[group('Build Virtal Machine Image')]
build-raw $target_image=("localhost/" + image_name) $tag=default_tag: && (_build-bib target_image tag "raw" "disk_config/disk.toml")

# Build an ISO virtual machine image
[group('Build Virtal Machine Image')]
build-iso $target_image=("localhost/" + image_name) $tag=default_tag: && (_build-bib target_image tag "iso" "disk_config/iso.toml")

# Build an ISO with Plasma DE by default
[group('Build Virtal Machine Image')]
build-iso-plasma $target_image=("localhost/" + image_name) $tag=default_tag: && (_build-bib target_image tag "iso" "disk_config/iso-kde.toml")

# Rebuild a QCOW2 virtual machine image
[group('Build Virtal Machine Image')]
rebuild-qcow2 $target_image=("localhost/" + image_name) $tag=default_tag: && (_rebuild-bib target_image tag "qcow2" "disk_config/disk.toml")

# Rebuild a RAW virtual machine image
[group('Build Virtal Machine Image')]
rebuild-raw $target_image=("localhost/" + image_name) $tag=default_tag: && (_rebuild-bib target_image tag "raw" "disk_config/disk.toml")

# Rebuild an ISO virtual machine image
[group('Build Virtal Machine Image')]
rebuild-iso $target_image=("localhost/" + image_name) $tag=default_tag: && (_rebuild-bib target_image tag "iso" "disk_config/iso.toml")

# Run a virtual machine with the specified image type and configuration
_run-vm $target_image $tag $type $config:
    #!/usr/bin/bash
    set -eoux pipefail

    # Determine the image file based on the type
    image_file="output/${type}/disk.${type}"
    if [[ $type == iso ]]; then
        image_file="output/bootiso/mt-os-installer.iso"
    fi

    # Build the image if it does not exist
    if [[ ! -f "${image_file}" ]]; then
        just "build-${type}" "$target_image" "$tag"
    fi

    # Determine an available port to use
    port=8006
    while grep -q :${port} <<< $(ss -tunalp); do
        port=$(( port + 1 ))
    done
    echo "Using Port: ${port}"
    echo "Connect to http://localhost:${port}"

    # Set up the arguments for running the VM
    run_args=()
    run_args+=(--rm --privileged)
    run_args+=(--pull=newer)
    run_args+=(--publish "127.0.0.1:${port}:8006")
    run_args+=(--env "CPU_CORES=4")
    run_args+=(--env "RAM_SIZE=8G")
    run_args+=(--env "DISK_SIZE=64G")
    run_args+=(--env "TPM=Y")
    run_args+=(--env "GPU=Y")
    run_args+=(--device=/dev/kvm)
    run_args+=(--volume "${PWD}/${image_file}":"/boot.${type}")
    run_args+=(docker.io/qemux/qemu)

    # Run the VM and open the browser to connect
    (sleep 30 && xdg-open http://localhost:"$port") &
    podman run "${run_args[@]}"

# Run a virtual machine from a QCOW2 image
[group('Run Virtal Machine')]
run-vm-qcow2 $target_image=("localhost/" + image_name) $tag=default_tag: && (_run-vm target_image tag "qcow2" "disk_config/disk.toml")

# Run a virtual machine from a RAW image
[group('Run Virtal Machine')]
run-vm-raw $target_image=("localhost/" + image_name) $tag=default_tag: && (_run-vm target_image tag "raw" "disk_config/disk.toml")

# Run a virtual machine from an ISO
[group('Run Virtal Machine')]
run-vm-iso $target_image=("localhost/" + image_name) $tag=default_tag: && (_run-vm target_image tag "iso" "disk_config/iso.toml")

# Run a virtual machine using systemd-vmspawn
[group('Run Virtal Machine')]
spawn-vm rebuild="0" type="qcow2" ram="6G":
    #!/usr/bin/env bash

    set -euo pipefail

    [ "{{ rebuild }}" -eq 1 ] && echo "Rebuilding the ISO" && just build-vm {{ rebuild }} {{ type }}

    systemd-vmspawn \
      -M "bootc-image" \
      --console=gui \
      --cpus=2 \
      --ram=$(echo {{ ram }}| /usr/bin/numfmt --from=iec) \
      --network-user-mode \
      --vsock=false --pass-ssh-key=false \
      -i ./output/**/*.{{ type }}


# Runs shell check on all Bash scripts
lint:
    #!/usr/bin/env bash
    set -eoux pipefail
    # Check if shellcheck is installed
    if ! command -v shellcheck &> /dev/null; then
        echo "shellcheck could not be found. Please install it."
        exit 1
    fi
    # Run shellcheck on all Bash scripts
    /usr/bin/find . -iname "*.sh" -type f -exec shellcheck "{}" ';'

# Runs shfmt on all Bash scripts
format:
    #!/usr/bin/env bash
    set -eoux pipefail
    # Check if shfmt is installed
    if ! command -v shfmt &> /dev/null; then
        echo "shellcheck could not be found. Please install it."
        exit 1
    fi
    # Run shfmt on all Bash scripts
    /usr/bin/find . -iname "*.sh" -type f -exec shfmt --write "{}" ';'
