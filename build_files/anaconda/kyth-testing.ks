# Kyth — Anaconda kickstart (testing branch)
#
# Used by two paths:
#   1. Live session (desktop icon):
#      Installer is launched with liveinst.
#      Source image is supplied by interactive-defaults.ks.
#
#   2. Direct boot (GRUB "Install Kyth" entry):
#      Embedded in the live initramfs at /run/install/ks.cfg via:
#        dracut --include /etc/anaconda/ks.cfg /run/install/ks.cfg
#      Loaded by kernel parameter: inst.ks=file:///run/install/ks.cfg
#
# Storage, timezone, language, and user account are configured interactively
# via the Anaconda WebUI. This kickstart only specifies the OS source.

# --device=link: activate the first interface that has carrier (avoids hardcoding
# eth0 which doesn't exist on most real hardware with predictable interface names).
network --bootproto=dhcp --device=link --activate --noipv6

# Pull Kyth (testing) from the container registry and install it to disk.
ostreecontainer --url="ghcr.io/mrtrick37/kyth:testing" --transport=registry --no-signature-verification

# Keep failure details visible in the live session.
%onerror
# Display error log in a dialog. Anaconda %onerror runs as root — run yad
# directly rather than via run0 which may not be available in this context.
DISPLAY=:0 XAUTHORITY=/home/liveuser/.Xauthority yad \
	--timeout=0 \
	--text-info \
	--no-buttons \
	--width=900 \
	--height=560 \
	--title="Kyth Installer Error" \
	--text="An installer error occurred. Please report this with the logs shown below." \
	< /tmp/anaconda.log || true
%end
