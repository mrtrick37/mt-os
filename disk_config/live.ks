# Kyth Live ISO kickstart
# Used with: livemedia-creator --ks=disk_config/live.ks --no-virt --make-iso
#
# Produces a bootable live ISO that starts a KDE Plasma session.
# The "Install Kyth" desktop icon launches Anaconda with kyth-install.ks,
# which installs Kyth from the container registry (ghcr.io/mrtrick37/kyth).

lang en_US.UTF-8
keyboard --vckeymap=us --xlayouts=us
timezone America/New_York

# Repos — Fedora 43
url --mirrorlist=https://mirrors.fedoraproject.org/mirrorlist?repo=fedora-43&arch=$basearch
repo --name=updates --mirrorlist=https://mirrors.fedoraproject.org/mirrorlist?repo=updates-released-f43&arch=$basearch
repo --name=rpmfusion-free --baseurl=https://mirrors.rpmfusion.org/free/fedora/43/$basearch/
repo --name=rpmfusion-nonfree --baseurl=https://mirrors.rpmfusion.org/nonfree/fedora/43/$basearch/

rootpw --lock --iscrypted locked
selinux --enforcing
firewall --enabled --service=mdns
network --bootproto=dhcp --device=link --activate
services --disabled="sshd" --enabled="NetworkManager,ModemManager"

# Disk layout (livemedia-creator loop image)
bootloader --location=none
zerombr
clearpart --all
part / --size=10240 --fstype=ext4

%packages
# KDE Plasma desktop
@^kde-desktop-environment
@kde-apps
@fonts
@networkmanager-submodules

# Live ISO infrastructure
dracut-live
liveinst
anaconda
anaconda-install-env-deps
anaconda-live

# Networking
NetworkManager-wifi
NetworkManager-bluetooth
iw
wpa_supplicant

# Basic utilities
bash-completion
curl
wget
git
vim-enhanced
htop
fastfetch
p7zip
p7zip-plugins

# Fonts
google-noto-fonts-common
google-noto-sans-fonts

# Remove unwanted
-initial-setup
-initial-setup-gui
-gnome-initial-setup
%end

%post
# ── Live user ──────────────────────────────────────────────────────────────
useradd -c "Live User" -G wheel liveuser
passwd -d liveuser

# Passwordless sudo for live session
echo "liveuser ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/liveuser
chmod 440 /etc/sudoers.d/liveuser

# ── SDDM auto-login ────────────────────────────────────────────────────────
mkdir -p /etc/sddm.conf.d
cat > /etc/sddm.conf.d/autologin.conf << 'SDDMEOF'
[Autologin]
User=liveuser
Session=plasma
SDDMEOF

# ── liveuser home ──────────────────────────────────────────────────────────
mkdir -p /home/liveuser/Desktop /home/liveuser/.config

# Breeze Dark theme (matches installed OS)
cat > /home/liveuser/.config/kdeglobals << 'KDEEOF'
[General]
ColorScheme=BreezeDark

[KDE]
LookAndFeelPackage=org.kde.breezedark.desktop
KDEEOF

cat > /home/liveuser/.config/plasmarc << 'PLASMAEOF'
[Theme]
name=breeze-dark
PLASMAEOF

# ── Install Kyth desktop shortcut ─────────────────────────────────────────
cat > /home/liveuser/Desktop/install-kyth.desktop << 'DESKEOF'
cat > /home/liveuser/Desktop/install-kyth.desktop << 'DESKEOF'
[Desktop Entry]
Name=Install Kyth
Comment=Install Kyth 43 to this computer
Exec=/usr/bin/kyth-install-launcher
Icon=anaconda
Terminal=false
Type=Application
Categories=System;
X-KDE-RunOnDiscreteGpu=false
DESKEOF
chmod +x /home/liveuser/Desktop/install-kyth.desktop

chown -R liveuser:liveuser /home/liveuser/
# Set Firefox as default browser for liveuser
sudo -u liveuser xdg-settings set default-web-browser firefox.desktop || true

# ── Kyth install wrapper script ───────────────────────────────────────────
cat > /usr/bin/kyth-install << 'SCRIPTEOF'
#!/bin/bash
# Launches Anaconda with the Kyth installation kickstart.
# The kickstart uses `ostreecontainer` to pull and install Kyth from
# ghcr.io/mrtrick37/kyth:latest — requires network access.
exec pkexec liveinst --kickstart /usr/share/kyth/install.ks "$@"
SCRIPTEOF
chmod +x /usr/bin/kyth-install

# ── Anaconda install kickstart (embedded in live image) ────────────────────
mkdir -p /usr/share/kyth
cp /run/install/repo/disk_config/kyth-install.ks /usr/share/kyth/install.ks 2>/dev/null || \
cat > /usr/share/kyth/install.ks << 'INSTALLEOF'
# Kyth installation kickstart
# Installs Kyth from the container registry via Anaconda ostreecontainer.
# This file is used by the "Install Kyth" desktop shortcut on the live ISO.

lang en_US.UTF-8
keyboard --vckeymap=us
timezone America/New_York
network --bootproto=dhcp --device=link --activate

# Pull Kyth OCI image from registry and install it to disk
ostreecontainer --url=ghcr.io/mrtrick37/kyth:latest --transport=registry --no-signature-verification

%packages
%end
INSTALLEOF

# ── OS branding ────────────────────────────────────────────────────────────
cat > /etc/os-release << 'OSEOF'
NAME="Kyth"
PRETTY_NAME="Kyth 43 Live"
ID=fedora
VERSION="43"
VERSION_ID="43"
ANSI_COLOR="0;34"
HOME_URL="https://example.com/kyth"
SUPPORT_URL="https://example.com/kyth/support"
BUG_REPORT_URL="https://example.com/kyth/issues"
OSEOF
%end

%post --nochroot
# Ensure the live squashfs is labeled correctly for SELinux
if [ -x /usr/sbin/restorecon ]; then
    /usr/sbin/restorecon -R /mnt/sysimage/home/liveuser/ 2>/dev/null || true
fi
%end
