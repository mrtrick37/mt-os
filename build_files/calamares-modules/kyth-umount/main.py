#!/usr/bin/env python3
# kyth-umount — Calamares Python job module
#
# Runs after the standard `users` exec jobs have created the user account.
# Cleans up the mounts that kyth-bootcinstall set up:
#
#   kyth_outer_mount  — temp dir where the root partition is mounted.
#                       proc, sys, dev, and var are bind-mounted inside the
#                       ostree deployment directory, which is itself a
#                       subdirectory of this mount.  A single recursive umount
#                       on this path tears down everything in the right order.

import os
import subprocess

import libcalamares


def pretty_name():
    return "Cleaning up installation mounts"


def _log(msg):
    libcalamares.utils.debug(f"kyth-umount: {msg}")


def run():
    gs = libcalamares.globalstorage

    outer_mount = (gs.value("kyth_outer_mount") or "").rstrip("/")

    if not outer_mount:
        _log("kyth_outer_mount not set — nothing to unmount")
        return None

    if not os.path.ismount(outer_mount) and not os.path.isdir(outer_mount):
        _log(f"{outer_mount} does not exist — nothing to unmount")
        return None

    _log(f"recursive umount of {outer_mount}")
    try:
        subprocess.run(["umount", "-R", outer_mount], check=True)
    except subprocess.CalledProcessError as e:
        # Non-fatal: log the failure but don't abort Calamares.
        libcalamares.utils.warning(
            f"kyth-umount: umount -R {outer_mount} failed (code {e.returncode}); "
            "mounts may still be active"
        )

    try:
        os.rmdir(outer_mount)
    except OSError:
        pass

    _log("done")
    return None
