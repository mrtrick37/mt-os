#!/bin/bash

# Detect Nvidia hardware
if lspci | grep -qi nvidia; then
  echo "Nvidia hardware detected. Applying kernel arguments and triggering akmods."
  # Append kernel arguments for Nvidia
  rpm-ostree kargs --append=rd.driver.blacklist=nouveau,nova_core --append=modprobe.blacklist=nouveau,nova_core --append=nvidia-drm.modeset=1
  # Trigger akmods for Nvidia
  akmods --force --kernels $(uname -r)
else
  echo "No Nvidia hardware detected. Skipping Nvidia configuration."
fi

exit 0
