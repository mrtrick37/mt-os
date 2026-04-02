export image_name := env("IMAGE_NAME", "kyth") # output image name, usually same as repo name, change as needed
export default_tag := env("DEFAULT_TAG", "latest")
export bib_image := env("BIB_IMAGE", "quay.io/centos-bootc/bootc-image-builder:latest")

alias build-vm := build-qcow2
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
    rm -rf output

# Sudo Clean Repo
[group('Utility')]
[private]
sudo-clean:
    just sudoif just clean

# Show a disk-usage summary: Docker images, build cache, and output/ ISOs
[group('Utility')]
disk-usage:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "── Docker ────────────────────────────────────────────────────────────────"
    docker system df
    echo ""
    echo "── Output ISOs ───────────────────────────────────────────────────────────"
    find output -name "*.iso" -o -name "*.qcow2" -o -name "*.raw" 2>/dev/null \
        | sort | xargs -r du -sh 2>/dev/null || echo "(none)"
    echo ""
    echo "── /var/tmp kyth-live build dirs ─────────────────────────────────────────"
    find /var/tmp -maxdepth 1 -name "kyth-live.*" -exec du -sh {} \; 2>/dev/null || echo "(none)"

# Remove old output ISOs — keeps only the current live ISO and current BIB ISO.
# Deletes: output/previous-built-iso/, output/archive/, stale manifest backups.
[group('Utility')]
clean-output:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Cleaning stale output artefacts..."
    sudo rm -rf output/previous-built-iso output/archive 2>/dev/null || true
    sudo rm -f  output/manifest-iso.json.bak 2>/dev/null || true
    sudo chown -R "$(id -u):$(id -g)" output/ 2>/dev/null || true
    echo "Remaining output files:"
    find output -name "*.iso" -o -name "*.qcow2" -o -name "*.raw" 2>/dev/null \
        | sort | xargs -r du -sh 2>/dev/null || echo "(none)"

# Prune Docker build cache and dangling (unreferenced) image layers.
# Keeps all named images (kyth:latest, kyth-live:build, kinoite-main:43).
# Run after a build to recover the reclaimable space shown in 'just disk-usage'.
[group('Utility')]
clean-docker:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Pruning Docker build cache..."
    docker builder prune -f
    echo ""
    echo "Pruning dangling image layers..."
    docker image prune -f
    echo ""
    docker system df

# Reclaim space specifically for live ISO dev loops.
# Removes stale kyth-live images/tags, prunes build cache/volumes,
# and deletes temporary VM disk and build directories.
[group('Utility')]
prune-live-dev:
    #!/usr/bin/env bash
    set -euo pipefail

    echo "── Removing stale kyth-live images ──────────────────────────────────────"
    docker images \
        | awk 'NR>1 {print $1":"$2}' \
        | grep '^kyth-live:' \
        | xargs -r docker rmi -f || true

    echo ""
    echo "── Pruning Docker cache/volumes ──────────────────────────────────────────"
    docker builder prune -af || true
    docker image prune -af || true
    docker volume prune -f || true

    echo ""
    echo "── Removing stale VM/build temp artefacts ───────────────────────────────"
    find /tmp -maxdepth 1 -type f -name 'kyth-live-test.qcow2' -delete || true
    find /var/tmp -maxdepth 2 -type f -name 'kyth-live-test.qcow2' -delete || true
    find /tmp -maxdepth 1 -type d -name 'kyth-vm-share-*' -exec rm -rf {} + || true
    find /var/tmp -maxdepth 1 -type d -name 'kyth-live.*' -exec rm -rf {} + || true

    echo ""
    echo "── Post-cleanup summary ───────────────────────────────────────────────────"
    df -h /tmp /var || true
    docker system df || true

# Full local cleanup: stale outputs + Docker cache.
# Does NOT remove localhost/kyth:latest or ghcr.io/ublue-os/kinoite-main:43
# since those are needed to build.
[group('Utility')]
clean-all: clean-output clean-docker

# Nuclear purge: reclaim maximum disk space.
# Removes ALL _build* temp dirs, old ISOs, stale /var/tmp build dirs,
# dangling Docker/Podman image layers, and Docker build cache.
# Keeps: current output/bootiso, output/live-iso, and all named images.
[group('Utility')]
purge:
    #!/usr/bin/env bash
    set -euo pipefail

    echo "── Stale _build* temp dirs in project root ───────────────────────────────"
    shopt -s nullglob
    build_dirs=( _build* )
    if [[ ${#build_dirs[@]} -gt 0 ]]; then
        sudo rm -rf "${build_dirs[@]}"
        printf '  removed: %s\n' "${build_dirs[@]}"
    else
        echo "  (none)"
    fi

    echo ""
    echo "── /var/tmp/kyth-live.* build dirs ──────────────────────────────────────"
    if sudo find /var/tmp -maxdepth 1 -name "kyth-live.*" -print -exec rm -rf {} + 2>/dev/null | grep -q .; then
        echo "  Done"
    else
        echo "  (none)"
    fi

    echo ""
    echo "── Old output artefacts (previous-built-iso, archive, manifest backups) ──"
    sudo rm -rf output/previous-built-iso output/archive 2>/dev/null || true
    sudo rm -f  output/manifest-iso.json.bak 2>/dev/null || true
    sudo chown -R "$(id -u):$(id -g)" output/ 2>/dev/null || true
    echo "  Done"

    echo ""
    echo "── Docker build cache ────────────────────────────────────────────────────"
    docker builder prune -f

    echo ""
    echo "── Docker dangling image layers ──────────────────────────────────────────"
    docker image prune -f

    echo ""
    echo "── Podman dangling image layers ──────────────────────────────────────────"
    if command -v podman &>/dev/null; then
        podman image prune -f
    else
        echo "  (podman not found)"
    fi

    echo ""
    echo "── Result ────────────────────────────────────────────────────────────────"
    df -h "$(pwd)"

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

# Build the base image from build_base/ and tag it as localhost/kyth:latest
# Override the upstream with: just build-base ghcr.io/ublue-os/kinoite-main:43
[group('Build')]
build-base base_image="ghcr.io/ublue-os/kinoite-main:43":
    #!/usr/bin/env bash
    # Ensure current user is in the docker group
    if ! id -nG "$USER" | grep -qw docker; then
        echo "Adding $USER to docker group (requires sudo)..."
        sudo usermod -aG docker "$USER"
        echo "You must log out and log back in for group changes to take effect."
    else
        echo "$USER is already in the docker group."
    fi

    if ! docker image inspect {{ base_image }} >/dev/null 2>&1; then
        docker pull {{ base_image }}
    else
        echo "Base image {{ base_image }} already present locally. Skipping pull."
    fi
    docker build --build-arg BASE_IMAGE={{ base_image }} --tag localhost/kyth-base:stable build_base/

# Build the full KythOS image (runs build_files/build.sh on top of kyth-base).
# Requires build-base to have run first.
build: build-base
    #!/usr/bin/env bash
    set -euo pipefail
    docker build \
        --build-arg ENABLE_ANANICY="${ENABLE_ANANICY:-1}" \
        --build-arg ENABLE_SCX="${ENABLE_SCX:-1}" \
        --tag localhost/kyth:latest .


# Command: _rootful_load_image
# Description: Ensures the target image is available to the root Docker daemon.
#              If already running as root/sudo, exits immediately (image is already accessible).
#              Otherwise, checks if the image exists in the user Docker store and, if so,
#              copies it to the root store via docker image save/load. Falls back to pulling
#              from the registry if the image is not found locally.
#
# Parameters:
#   $target_image - The name of the target image to be loaded or pulled.
#   $tag - The tag of the target image to be loaded or pulled. Default is 'default_tag'.

_rootful_load_image $target_image=image_name $tag=default_tag:
    #!/usr/bin/bash
    set -eoux pipefail

    # Check if already running as root or under sudo
    if [[ -n "${SUDO_USER:-}" || "${UID}" -eq "0" ]]; then
        echo "Already root or running under sudo; image is already accessible to the root Docker daemon."
        exit 0
    fi

    # Try to resolve the image tag using docker inspect
    set +e
        resolved_tag=$(docker inspect --format '{{"{{.RepoTags}}"}}' "${target_image}:${tag}" | jq -r '.[0]')
    return_code=$?
    set -e

        USER_IMG_ID=$(docker images --filter reference="${target_image}:${tag}" --format "'{{ '{{.ID}}' }}'")

    if [[ $return_code -eq 0 ]]; then
        # If the image is found, load it into rootful docker
        ID=$(just sudoif docker images --filter reference="${target_image}:${tag}" --format "'{{ '{{.ID}}' }}'")
        if [[ "$ID" != "$USER_IMG_ID" ]]; then
            # If the image ID is not found or different from user, copy the image from user docker to root docker
            COPYTMP=$(mktemp -p /var/tmp -d -t _build_docker_scp.XXXXXXXXXX)
            just sudoif TMPDIR=${COPYTMP} docker image save "${target_image}:${tag}" | docker image load
            rm -rf "${COPYTMP}"
        fi
    else
        # If the image is not found, pull it from the repository
        just sudoif docker pull "${target_image}:${tag}"
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
        # Provide sensible defaults so installer UI shows KythOS even when labels
        # are missing from the base image.
        PRODUCT_NAME="KythOS"
        PRODUCT_VERSION="43"
        set +e
        labels_json=$(docker inspect "${target_image}:${tag}" 2>/dev/null | jq -c '.[0].Config.Labels // {}' 2>/dev/null || true)
        set -e
        if [[ -n "${labels_json}" && "${labels_json}" != "null" ]]; then
            PRODUCT_NAME=$(echo "${labels_json}" | jq -r '."org.opencontainers.image.title" // empty' || true)
            PRODUCT_VERSION=$(echo "${labels_json}" | jq -r '."org.opencontainers.image.version" // empty' || true)
        fi
        # Do not pass --version to bootc-image-builder (it treats --version as a boolean).
        # We patch generated manifest files below to set product/version when available.

        # Enable debug logging from bootc-image-builder to surface why lorax product/version are empty
        args+="--log-level=debug "

        # BIB needs to pull the image from a registry. Push to a temporary local
        # registry so BIB can reach it via --net=host without touching the image store.
        REG_PORT=5099
        docker run -d --rm --name kyth-bib-registry \
            -p "127.0.0.1:${REG_PORT}:5000" registry:2
        trap 'docker stop kyth-bib-registry 2>/dev/null || true' EXIT
        BIB_IMAGE_REF="localhost:${REG_PORT}/${target_image##*/}:${tag}"
        docker tag "${target_image}:${tag}" "${BIB_IMAGE_REF}"
        docker push "${BIB_IMAGE_REF}"

        sudo docker run \
            --rm \
            --privileged \
            --pull=newer \
            --net=host \
            --security-opt label=type:unconfined_t \
            $KEY_MOUNT \
            -v $(pwd)/${config}:/config.toml:ro \
            -v $BUILDTMP:/output \
            "${bib_image}" \
            ${args} \
            "${BIB_IMAGE_REF}"

        docker stop kyth-bib-registry 2>/dev/null || true

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
    # Rename standard install ISO to a consistent KythOS filename
    if sudo test -f output/bootiso/install.iso; then
        sudo mv -f output/bootiso/install.iso output/bootiso/kyth-installer.iso || true
    fi
    sudo rmdir $BUILDTMP || true
    sudo chown -R $USER:$USER output/

    # Print absolute path to produced ISO if present (helps CI and users find artifact)
    if sudo test -f output/bootiso/kyth-installer.iso; then
        ISO_PATH=$(readlink -f output/bootiso/kyth-installer.iso)
        echo "Produced ISO: ${ISO_PATH}"
    fi


# Build a QCOW2 virtual machine image
[group('Build Virtual Machine Image')]
build-qcow2 $target_image=("localhost/" + image_name) $tag=default_tag: && (_build-bib target_image tag "qcow2" "disk_config/disk.toml")

# Build a RAW virtual machine image
[group('Build Virtual Machine Image')]
build-raw $target_image=("localhost/" + image_name) $tag=default_tag: && (_build-bib target_image tag "raw" "disk_config/disk.toml")

# Build an ISO virtual machine image
[group('Build Virtual Machine Image')]
build-iso $target_image=("localhost/" + image_name) $tag=default_tag: && (_build-bib target_image tag "iso" "disk_config/iso.toml")

# Build a live ISO with the KythOS web installer (netinstall — pulls OS from
# the registry at install time via bootc install to-disk).
# Pass source_tag to target a different branch: just build-live-iso testing
[group('Build Virtual Machine Image')]
build-live-iso source_tag="latest":
    #!/usr/bin/env bash
    set -euo pipefail
    SOURCE_TAG={{ source_tag }} bash build_files/build-live-iso.sh

# Force a full rebuild of the live ISO, ignoring the cached container layer.
# Use after changing Containerfile.live or any file it COPYs.
[group('Build Virtual Machine Image')]
rebuild-live-iso source_tag="latest":
    #!/usr/bin/env bash
    set -euo pipefail
    SOURCE_TAG={{ source_tag }} REBUILD_IMAGE=1 bash build_files/build-live-iso.sh

# Boot the live ISO in a VM (BIOS, web UI at http://localhost:PORT).
# Uses the dedicated artifact name from build-live-iso.sh:
#   output/live-iso/kyth-live-<tag>.iso
[group('Run Virtual Machine')]
run-live-iso source_tag="latest":
    #!/usr/bin/bash
    set -eoux pipefail

    image_file="output/live-iso/kyth-live-{{ source_tag }}.iso"
    if [[ ! -f "${image_file}" ]]; then
        just build-live-iso {{ source_tag }}
    fi

    port=8006
    while grep -q ":${port}" <<< $(ss -tunalp); do
        port=$(( port + 1 ))
    done
    echo "Using Port: ${port}"
    echo "Connect to http://localhost:${port}"

    (sleep 30 && xdg-open http://localhost:"$port") &
    docker run \
        --rm --privileged \
        --pull missing \
        --publish "127.0.0.1:${port}:8006" \
        --env "CPU_CORES=4" \
        --env "RAM_SIZE=8G" \
        --env "DISK_SIZE=64G" \
        --env "GPU=Y" \
        --device=/dev/kvm \
        --volume "${PWD}/${image_file}:/boot.iso" \
        docker.io/qemux/qemu

# Boot the live ISO directly in native QEMU (SPICE window, better clipboard).
# Useful when noVNC copy/paste is awkward while collecting installer logs.
[group('Run Virtual Machine')]
run-live-iso-native source_tag="latest":
    #!/usr/bin/bash
    set -eoux pipefail

    image_file="output/live-iso/kyth-live-{{ source_tag }}.iso"
    if [[ ! -f "${image_file}" ]]; then
        just build-live-iso {{ source_tag }}
    fi

    disk_dir="/var/tmp/kyth-vm-disks-${USER}"
    mkdir -p "${disk_dir}"
    disk_img="${disk_dir}/kyth-live-test.qcow2"

    # Optional one-shot reset for a clean VM install target.
    if [[ "${LIVE_ISO_VM_RESET:-0}" == "1" ]]; then
        rm -f "${disk_img}"
    fi

    # Fail fast before booting when host free space is too low for install writes.
    avail_bytes=$(df --output=avail -B1 "${disk_dir}" | tail -n 1 | tr -d '[:space:]')
    min_bytes=$((30 * 1024 * 1024 * 1024))
    if [[ "${avail_bytes}" -lt "${min_bytes}" ]]; then
        echo "Insufficient free space for live ISO VM disk writes on $(df --output=target "${disk_dir}" | tail -n 1)."
        echo "Need >= 30 GiB free, found $((avail_bytes / 1024 / 1024 / 1024)) GiB."
        echo "Run: just prune-live-dev"
        exit 1
    fi

    if [[ ! -f "${disk_img}" ]]; then
        qemu-img create -f qcow2 -o preallocation=metadata,lazy_refcounts=on "${disk_img}" 64G
    fi

    # Host/guest shared folder for collecting logs from the VM.
    # Use /var/tmp consistently to avoid tmpfs quota issues seen under /tmp.
    share_dir="/var/tmp/kyth-vm-share-${USER}"
    mkdir -p "${share_dir}"
    serial_log="${share_dir}/qemu-serial.log"
    qemu_log="${share_dir}/qemu-debug.log"
    rm -f "${serial_log}" "${qemu_log}"
    echo "Host shared folder: ${share_dir}"
    echo "Serial log on host: ${serial_log}"
    echo "QEMU debug log on host: ${qemu_log}"
    echo "In VM, run: sudo mkdir -p /var/mnt/hostshare && sudo mount -t 9p -o trans=virtio,version=9p2000.L,cache=none hostshare /var/mnt/hostshare"

    qemu-system-x86_64 \
        -enable-kvm \
        -cpu host \
        -smp 4 \
        -m 8G \
        -machine q35 \
        -cdrom "${image_file}" \
        -boot order=c,once=d \
        -drive file="${disk_img}",if=virtio,format=qcow2 \
        -device virtio-vga \
        -display none \
        -spice port=5931,disable-ticketing=on,disable-copy-paste=off,disable-agent-file-xfer=off \
        -device virtio-serial \
        -chardev spicevmc,id=vdagent,name=vdagent \
        -device virtserialport,chardev=vdagent,name=com.redhat.spice.0 \
        -device virtio-net-pci,netdev=net0 \
        -netdev user,id=net0,hostfwd=tcp::2223-:22 \
        -device virtio-rng-pci \
        -device qemu-xhci \
        -device usb-tablet \
        -d guest_errors \
        -serial "file:${serial_log}" \
        -D "${qemu_log}" \
        -virtfs local,path="${share_dir}",mount_tag=hostshare,security_model=mapped-xattr,id=hostshare \
        &
    QEMU_PID=$!
    sleep 2
    rv_cache="/var/tmp/kyth-remote-viewer-${USER}"
    mkdir -p "${rv_cache}"
    env XDG_CACHE_HOME="${rv_cache}" TMPDIR="/var/tmp" remote-viewer spice://localhost:5931 &
    wait "${QEMU_PID}"

# Alternate live ISO native run target that keeps legacy boot behavior (-no-reboot).
# Useful for A/B testing reboot-path issues against the reboot-friendly target above.
[group('Run Virtual Machine')]
run-live-iso-native-legacy source_tag="latest":
    #!/usr/bin/bash
    set -eoux pipefail

    image_file="output/live-iso/kyth-live-{{ source_tag }}.iso"
    if [[ ! -f "${image_file}" ]]; then
        just build-live-iso {{ source_tag }}
    fi

    disk_dir="/var/tmp/kyth-vm-disks-${USER}"
    mkdir -p "${disk_dir}"
    disk_img="${disk_dir}/kyth-live-test.qcow2"

    if [[ "${LIVE_ISO_VM_RESET:-0}" == "1" ]]; then
        rm -f "${disk_img}"
    fi

    avail_bytes=$(df --output=avail -B1 "${disk_dir}" | tail -n 1 | tr -d '[:space:]')
    min_bytes=$((30 * 1024 * 1024 * 1024))
    if [[ "${avail_bytes}" -lt "${min_bytes}" ]]; then
        echo "Insufficient free space for live ISO VM disk writes on $(df --output=target "${disk_dir}" | tail -n 1)."
        echo "Need >= 30 GiB free, found $((avail_bytes / 1024 / 1024 / 1024)) GiB."
        echo "Run: just prune-live-dev"
        exit 1
    fi

    if [[ ! -f "${disk_img}" ]]; then
        qemu-img create -f qcow2 -o preallocation=metadata,lazy_refcounts=on "${disk_img}" 64G
    fi

    share_dir="/var/tmp/kyth-vm-share-${USER}"
    mkdir -p "${share_dir}"
    serial_log="${share_dir}/qemu-serial.log"
    qemu_log="${share_dir}/qemu-debug.log"
    rm -f "${serial_log}" "${qemu_log}"
    echo "Host shared folder: ${share_dir}"
    echo "Serial log on host: ${serial_log}"
    echo "QEMU debug log on host: ${qemu_log}"
    echo "In VM, run: sudo mkdir -p /var/mnt/hostshare && sudo mount -t 9p -o trans=virtio,version=9p2000.L,cache=none hostshare /var/mnt/hostshare"

    qemu-system-x86_64 \
        -enable-kvm \
        -cpu host \
        -smp 4 \
        -m 8G \
        -machine q35 \
        -no-reboot \
        -no-shutdown \
        -cdrom "${image_file}" \
        -boot order=d \
        -drive file="${disk_img}",if=virtio,format=qcow2 \
        -device virtio-vga \
        -display none \
        -spice port=5932,disable-ticketing=on,disable-copy-paste=off,disable-agent-file-xfer=off \
        -device virtio-serial \
        -chardev spicevmc,id=vdagent,name=vdagent \
        -device virtserialport,chardev=vdagent,name=com.redhat.spice.0 \
        -device virtio-net-pci,netdev=net0 \
        -netdev user,id=net0,hostfwd=tcp::2224-:22 \
        -device virtio-rng-pci \
        -device qemu-xhci \
        -device usb-tablet \
        -d guest_errors \
        -serial "file:${serial_log}" \
        -D "${qemu_log}" \
        -virtfs local,path="${share_dir}",mount_tag=hostshare,security_model=mapped-xattr,id=hostshare \
        &
    QEMU_PID=$!
    sleep 2
    rv_cache="/var/tmp/kyth-remote-viewer-${USER}"
    mkdir -p "${rv_cache}"
    env XDG_CACHE_HOME="${rv_cache}" TMPDIR="/var/tmp" remote-viewer spice://localhost:5932 &
    wait "${QEMU_PID}"

# Run a virtual machine with the specified image type and configuration
_run-vm $target_image $tag $type $config:
    #!/usr/bin/bash
    set -eoux pipefail

    # Determine the image file based on the type
    image_file="output/${type}/disk.${type}"
    if [[ $type == iso ]]; then
        image_file="output/bootiso/kyth-installer.iso"
    fi

    # Build the image if it does not exist
    if [[ ! -f "${image_file}" ]]; then
        just "build-${type}" "$target_image" "$tag"
    fi

    # Determine an available port to use
    port=8006
    while grep -q ":${port}" <<< $(ss -tunalp); do
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
    docker run "${run_args[@]}"

# Run a virtual machine from a QCOW2 image
[group('Run Virtual Machine')]
run-vm-qcow2 $target_image=("localhost/" + image_name) $tag=default_tag: && (_run-vm target_image tag "qcow2" "disk_config/disk.toml")

# Run a virtual machine from a RAW image
[group('Run Virtual Machine')]
run-vm-raw $target_image=("localhost/" + image_name) $tag=default_tag: && (_run-vm target_image tag "raw" "disk_config/disk.toml")

# Run a virtual machine from an ISO
[group('Run Virtual Machine')]
run-vm-iso $target_image=("localhost/" + image_name) $tag=default_tag: && (_run-vm target_image tag "iso" "disk_config/iso.toml")

# Run a virtual machine using systemd-vmspawn
[group('Run Virtual Machine')]
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
