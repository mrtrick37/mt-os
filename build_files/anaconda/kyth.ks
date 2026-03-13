# Kyth — Anaconda kickstart
#
# Used by two paths:
#   1. Live session (desktop icon):
#      Loaded from /etc/anaconda/kyth.ks by the kyth-anaconda-live wrapper,
#      which passes it to anaconda via --kickstart.
#
#   2. Direct boot (GRUB "Install Kyth" entry):
#      Embedded in the live initramfs at /run/install/ks.cfg via:
#        dracut --include /etc/anaconda/kyth.ks /run/install/ks.cfg
#      Loaded by kernel parameter: inst.ks=file:///run/install/ks.cfg
#
# Storage, timezone, language, and user account are configured interactively
# via the Anaconda WebUI. This kickstart only specifies the OS source.

network --bootproto=dhcp --device=eth0 --activate --noipv6
%post
# Ensure NetworkManager is enabled for live session
nmcli device set eth0 managed yes || true
%end

# Pull Kyth from the container registry and install it to disk.
ostreecontainer --url="ghcr.io/mrtrick37/kyth:latest" --no-signature-verification

%packages
%end
