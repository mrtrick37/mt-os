# Kyth Installation Kickstart (legacy / BIB installer ISO path)
# This file is used by bootc-image-builder installer ISOs (iso.toml / iso-kde.toml).
# The live desktop ISO uses bootc install to-disk instead (build_files/kyth-install.sh).

lang en_US.UTF-8
keyboard --vckeymap=us
timezone America/New_York
network --bootproto=dhcp --device=link --activate

# Install Kyth OCI image from ghcr.io
ostreecontainer --url=ghcr.io/mrtrick37/kyth:latest --transport=registry --no-signature-verification

%packages
%end
