# mt-OS

This repository contains the mt-OS image template and build pipelines. It is configured to:

- Build a custom OCI image and produce disk artifacts (ISO, qcow2, raw) using `bootc-image-builder`.
- Provide a `just build-iso-plasma` recipe which produces an installer ISO with Plasma as the default DE.
- Mount local RPM GPG keys (e.g. `RPM-GPG-KEY-terra43-mesa` or a `pki/rpm-gpg/` directory) into the build container so DNF depsolve can access repository signing keys.
- Include installer kickstart `%pre` helpers that prompt for networking, mirror installer logs into `/tmp/program-log` (so Anaconda shows packaging/install logs), and suppress noisy services such as `brltty`.

Use this repo to iterate on an image, create install media, and test the interactive installer in a VM.

## Community

If you have questions about the original template, these resources may help:

- Universal Blue Forums: https://universal-blue.discourse.group/
- Universal Blue Discord: https://discord.gg/WEu6BdFEtp
- bootc discussion forums: https://github.com/bootc-dev/bootc/discussions

## Quickstart / Prerequisites

- `podman` or `docker` installed on the host
- `just` installed for recipe execution
- `sudo` access for building ISOs locally

## Local build & testing

- Build ISO (local):

```bash
sudo just build-iso-plasma
```

- Capture build output to a file:

```bash
sudo just build-iso-plasma 2>&1 | tee ~/mt-os-build.log
```

- If you need a faithful terminal transcript (records prompts), use `script` if available:

```bash
sudo script -q -c "just build-iso-plasma" ~/mt-os-build.script.log
```

If the build fails during DNF depsolve complaining about a missing GPG key, put the key file into this repository root (for example `RPM-GPG-KEY-terra43-mesa`) or a `pki/rpm-gpg/` subdirectory. The `_build-bib` recipe will mount those into the build container at `/etc/pki/rpm-gpg` when present.

CI artifacts

- When the GitHub Actions `build-disk.yml` workflow runs the ISO build it will upload a named artifact `mt-os-installer.iso` (in addition to the full output directory). You can download that artifact from the workflow run artifacts page.

## Installer notes

Kickstart files live in `disk_config/`. They include a `%pre` which:

- Attempts wired DHCP and, if not connected, offers a guided Wi‑Fi prompt via the installer console.
- Stops and masks `brltty` to reduce noisy bluetooth warnings.
- Mirrors packaging and installer logs into `/tmp/program-log` and periodically copies them into paths Anaconda reads so the UI displays logs beneath the progress bar.

If you have access to the installer shell and need to start log mirroring manually, run:

```bash
mkdir -p /tmp/program-log && \
  tail -n +1 -F /tmp/packaging.log /tmp/storage-log /tmp/anaconda.log /tmp/installation.log /tmp/install.log 2>/dev/null >> /tmp/program-log &
```

## Where to look next

- `Justfile` — recipes and `_build-bib` container invocation
- `Containerfile` — image customization and `build_files/build.sh`
- `disk_config/iso-kde.toml` and `disk_config/iso-gnome.toml` — kickstart entries and `%pre` customizations

If you'd like, I can:

- Run a quick grep to confirm all README references updated,
- Add an FAQ section for common build failures (GPG key, depsolve), or
- Update `build-disk.yml` docs with the mt-OS defaults.

## FAQ

- **Q: Build fails with "Failed to retrieve GPG key" or DNF depsolve errors mentioning `/etc/pki/rpm-gpg/RPM-GPG-KEY-*`. What do I do?**

  A: Place the repository GPG key file(s) into the repository root (example: `RPM-GPG-KEY-terra43-mesa`) or under a `pki/rpm-gpg/` directory. The `_build-bib` recipe will mount matching files into the build container at `/etc/pki/rpm-gpg` so DNF can read them. Example:

  ```bash
  cp /etc/pki/rpm-gpg/RPM-GPG-KEY-terra43-mesa ~/git/mt-os/
  git add RPM-GPG-KEY-terra43-mesa
  git commit -m "Add terra43 mesa GPG key for builder"
  ```

- **Q: The installer UI doesn't show packaging/install logs under the progress bar. How can I make them appear?**

  A: Our kickstarts attempt to mirror installer logs into `/tmp/program-log`. If you're in a running installer shell you can start mirroring immediately with:

  ```bash
  mkdir -p /tmp/program-log && \
    tail -n +1 -F /tmp/packaging.log /tmp/storage-log /tmp/anaconda.log /tmp/installation.log /tmp/install.log 2>/dev/null >> /tmp/program-log &
  ```

  Also ensure SELinux contexts are sane (the `%pre` in the kickstart tries `restorecon` and falls back to `chcon -t var_log_t`). If logs still do not appear, paste the last 200 lines of `/tmp/program-log` here and I'll help diagnose.
