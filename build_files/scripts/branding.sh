#!/bin/bash

set -euo pipefail

# Kernel was installed in the build_base layer. Re-derive the version here
# since it's needed for the Plymouth initramfs rebuild.
CACHYOS_KVER=$(basename "$(echo /usr/lib/modules/*cachyos*)")

# ── Display / resolution auto-detection ──────────────────────────────────────
# First-login autostart: run kscreen-doctor to set all outputs to their
# preferred (auto) mode.  Works for both hardware and VMs.  Removes itself
# so it only fires once per user.
mkdir -p /etc/skel/.config/autostart
cat > /etc/skel/.config/autostart/kyth-set-resolution.desktop <<'RESEOF'
[Desktop Entry]
Type=Application
Name=Kyth: Set display resolution
Exec=/usr/bin/kyth-set-resolution
X-KDE-autostart-after=panel
Hidden=false
NoDisplay=true
RESEOF

cat > /usr/bin/kyth-set-resolution <<'SCRIPTEOF'
#!/usr/bin/env python3
# Set every connected output to its preferred (first-listed) mode.
# kscreen-doctor -o output format:
#   Output: 1 Virtual-1 enabled connected
#     Modes: 1:1920x1080@60  2:1280x720@60  ...
# Runs once on first login per user, then removes itself.

import os, re, subprocess, time

# Give KDE's display stack time to fully initialize before querying
time.sleep(3)

result = subprocess.run(['kscreen-doctor', '-o'], capture_output=True, text=True)

current_output = None
for line in result.stdout.splitlines():
    line = line.strip()
    # Match "Output: 1 Virtual-1 enabled connected" — name is the second word
    m = re.match(r'^Output:\s+\d+\s+(\S+)', line)
    if m:
        current_output = m.group(1)
        continue
    # Match "Modes: 1:1920x1080@60  2:..." — first mode is the preferred resolution
    if current_output and re.match(r'^Modes:', line):
        modes = re.findall(r'\d+:(\d+x\d+@[\d.]+)', line)
        if modes:
            subprocess.run([
                'kscreen-doctor',
                f'output.{current_output}.enable',
                f'output.{current_output}.mode.{modes[0]}',
            ], check=False)
        current_output = None

autostart = os.path.expanduser('~/.config/autostart/kyth-set-resolution.desktop')
try:
    os.unlink(autostart)
except OSError:
    pass
SCRIPTEOF
chmod +x /usr/bin/kyth-set-resolution

# Ensure the built image advertises the Kyth product name. Some boot/installer
# menus derive their display strings from `/etc/os-release` or similar metadata.
# We overwrite or create `/etc/os-release` with Kyth values so boot menus show
# "Kyth" instead of upstream branding.
cat > /etc/os-release <<'EOF' || true
NAME="Kyth"
PRETTY_NAME="Kyth 43"
ID=fedora
VERSION="43"
VERSION_ID="43"
ANSI_COLOR="0;34"
HOME_URL="https://github.com/mrtrick37/kyth"
SUPPORT_URL="https://github.com/mrtrick37/kyth/discussions"
BUG_REPORT_URL="https://github.com/mrtrick37/kyth/issues"
EOF

# ── Topgrade config for all new users ────────────────────────────────────────
# Disable rpm-ostree step: on a bootc system rpm-ostree upgrade pulls from the
# upstream Kinoite ostree remote, not the Kyth container registry.
# Replace it with a bootc upgrade custom step so topgrade does the right thing.
mkdir -p /etc/skel/.config
cat > /etc/skel/.config/topgrade.toml <<'TOPGRADEEOF'
[misc]
# rpm-ostree upgrade pulls from the base Kinoite ostree repo, not Kyth.
# System updates go through bootc instead (see [commands] below).
disable = ["rpm_ostree"]

[commands]
"Kyth system update" = "sudo bootc upgrade"
TOPGRADEEOF

# ── Default KDE theme for all new users via /etc/skel ─────────────────────────
mkdir -p /etc/skel/.config
cat > /etc/skel/.config/kdeglobals <<'KDEEOF'
[General]
ColorScheme=BreezeDark

[KDE]
LookAndFeelPackage=org.kde.breezedark.desktop
KDEEOF

cat > /etc/skel/.config/plasmarc <<'PLASMAEOF'
[Theme]
name=breeze-dark
PLASMAEOF

# ── Plasma / PowerDevil hardening ─────────────────────────────────────────────
# KDE documents POWERDEVIL_NO_DDCUTIL=1 as a supported workaround when
# PowerDevil's DDC/CI monitor integration causes instability. On Kyth's AMD
# laptop targets, repeated libddcutil/backlight activity has correlated with
# display-timeout/pageflip failures, so default to the safer path:
# keep PowerDevil running, but stop it from talking to external monitors via
# ddcutil. Tradeoff: external monitor brightness control via DDC/CI is disabled.
#
# Add a second guardrail at the libddcutil layer as well. This keeps any
# consumer that does load libddcutil from starting display-watch threads, which
# are a known source of instability on some monitor/GPU combinations.
mkdir -p /etc/xdg/plasma-workspace/env /etc/xdg/ddcutil
cat > /etc/environment.d/90-kyth-powerdevil.conf <<'POWERDEVILEOF'
POWERDEVIL_NO_DDCUTIL=1
POWERDEVILEOF
cat > /etc/xdg/plasma-workspace/env/90-kyth-powerdevil.sh <<'POWERDEVILSHEOF'
#!/bin/sh
export POWERDEVIL_NO_DDCUTIL=1
POWERDEVILSHEOF
chmod +x /etc/xdg/plasma-workspace/env/90-kyth-powerdevil.sh
cat > /etc/xdg/ddcutil/ddcutilrc <<'DDCUTILRCEOF'
[libddcutil]
options: --disable-watch-displays
DDCUTILRCEOF

# ── Kyth wallpaper package ────────────────────────────────────────────────────
# Install as a proper KDE wallpaper package so the L&F lookup 'Image=kyth' works.
mkdir -p /usr/share/wallpapers/kyth/contents/images
cp /ctx/wallpaper/kyth-wallpaper.svg \
    /usr/share/wallpapers/kyth/contents/images/1920x1080.svg
printf '{"KPlugin":{"Authors":[{"Name":"Kyth"}],"Id":"kyth","Name":"Kyth","License":"CC-BY-SA-4.0"},"KPackageStructure":"Wallpaper/Images"}\n' \
    > /usr/share/wallpapers/kyth/metadata.json

# Patch all L&F defaults (Fedora variants + Breeze) to use Kyth wallpaper.
# Fedora Kinoite ships org.fedoraproject.fedora*.desktop themes that set
# Image=Fedora; we replace that in every theme so no L&F can restore the
# stock Fedora rocket wallpaper.
find /usr/share/plasma/look-and-feel -name defaults | while read -r f; do
    sed -i 's/^Image=.*/Image=kyth/' "$f"
    grep -q '^Image=' "$f" || printf '\n[Wallpaper]\nImage=kyth\n' >> "$f"
done

# System-wide XDG fallback — applied to every user before their personal
# config exists, so first-boot always shows the Kyth wallpaper.
mkdir -p /etc/xdg
cat > /etc/xdg/plasma-org.kde.plasma.desktop-appletsrc <<'XDGPLASMAEOF'
[Containments][1][Wallpaper][org.kde.image][General]
Image=/usr/share/wallpapers/kyth/contents/images/1920x1080.svg
XDGPLASMAEOF

# ── Kyth logo as system icon ──────────────────────────────────────────────────
# KDE Plasma 6 Kickoff looks up icons in this order:
#   start-here-kde-plasma → start-here-kde → start-here
# Install under all three names in hicolor (universal fallback), breeze
# (default KDE theme), and breeze-dark so every combination is covered.
for theme_dir in \
    /usr/share/icons/hicolor/scalable/apps \
    /usr/share/icons/breeze/apps/scalable \
    /usr/share/icons/breeze-dark/apps/scalable; do
    mkdir -p "${theme_dir}"
    cp /ctx/calamares/branding/kyth/kyth-logo.svg "${theme_dir}/kyth.svg"
    cp /ctx/calamares/branding/kyth/kyth-logo.svg "${theme_dir}/start-here.svg"
    cp /ctx/calamares/branding/kyth/kyth-logo.svg "${theme_dir}/start-here-kde.svg"
    cp /ctx/calamares/branding/kyth/kyth-logo.svg "${theme_dir}/start-here-kde-plasma.svg"
done
gtk-update-icon-cache -f /usr/share/icons/hicolor/    2>/dev/null || true
gtk-update-icon-cache -f /usr/share/icons/breeze/      2>/dev/null || true
gtk-update-icon-cache -f /usr/share/icons/breeze-dark/ 2>/dev/null || true

# ── First-login script: set Kickoff launcher icon to Kyth logo ────────────────
# Belt-and-suspenders: the icon theme install above should be enough, but this
# also writes the icon key directly into each user's Kickoff applet config in
# case the theme lookup is overridden by a previously cached value.
cat > /usr/bin/kyth-set-kickoff-icon <<'KICKOFEOF'
#!/usr/bin/env python3
import os, re, subprocess

aprc = os.path.expanduser("~/.config/plasma-org.kde.plasma.desktop-appletsrc")
autostart = os.path.expanduser("~/.config/autostart/kyth-set-kickoff-icon.desktop")

if os.path.exists(aprc):
    content = open(aprc).read()
    for m in re.finditer(
        r'^\[Containments\]\[(\d+)\]\[Applets\]\[(\d+)\]',
        content, re.MULTILINE
    ):
        cont, applet = m.group(1), m.group(2)
        body_start = m.end()
        nxt = re.search(r'^\[', content[body_start:], re.MULTILINE)
        body = content[body_start: body_start + nxt.start()] if nxt else content[body_start:]
        if 'plugin=org.kde.plasma.kickoff' in body:
            subprocess.run([
                'kwriteconfig6', '--file', aprc,
                '--group', 'Containments', '--group', cont,
                '--group', 'Applets', '--group', applet,
                '--group', 'Configuration', '--group', 'General',
                '--key', 'icon', 'start-here-kde-plasma',
            ], check=False)

try:
    os.unlink(autostart)
except OSError:
    pass
KICKOFEOF
chmod +x /usr/bin/kyth-set-kickoff-icon

mkdir -p /etc/skel/.config/autostart
cat > /etc/skel/.config/autostart/kyth-set-kickoff-icon.desktop <<'AUTOSTARTEOF'
[Desktop Entry]
Type=Application
Name=Kyth: Set Kickoff Icon
Exec=/usr/bin/kyth-set-kickoff-icon
X-KDE-autostart-after=panel
Hidden=false
NoDisplay=true
AUTOSTARTEOF

cat > /etc/skel/.config/plasma-org.kde.plasma.desktop-appletsrc <<'PLASMADESKTOPEOF'
[Containments][1]
wallpaperplugin=org.kde.image

[Containments][1][Wallpaper][org.kde.image][General]
Image=/usr/share/wallpapers/kyth/contents/images/1920x1080.svg
PLASMADESKTOPEOF

# ── MangoHud defaults ─────────────────────────────────────────────────────────
# Ship a sensible system-wide config so MangoHud shows useful info out of the box.
# Users can override in ~/.config/MangoHud/MangoHud.conf or per-app.
mkdir -p /etc/MangoHud
install -m 0644 /ctx/MangoHud.conf /etc/MangoHud/MangoHud.conf

# ── Outlook PWA ───────────────────────────────────────────────────────────────
# Adds Microsoft Outlook to the Internet section of the app launcher via a
# .desktop file that opens it as a Brave PWA (no browser chrome).
mkdir -p /usr/share/applications
cat > /usr/share/applications/outlook-pwa.desktop <<'OUTLOOKEOF'
[Desktop Entry]
Version=1.0
Name=Outlook
Comment=Microsoft Outlook — email and calendar
Exec=brave-browser --app=https://outlook.live.com/mail/ %U
Icon=outlook-pwa
Terminal=false
Type=Application
Categories=Network;Email;
StartupWMClass=outlook.live.com__mail_
StartupNotify=true
OUTLOOKEOF
mkdir -p /usr/share/icons/hicolor/192x192/apps
cp /ctx/icons/outlook-pwa.png /usr/share/icons/hicolor/192x192/apps/outlook-pwa.png
gtk-update-icon-cache -f /usr/share/icons/hicolor/ 2>/dev/null || true

# Remove Waydroid desktop/menu entries and related files if present
# (some base images include a Waydroid helper that we don't ship in Kyth)
rm -f /usr/share/applications/*waydroid*.desktop || true
rm -f /usr/local/share/applications/*waydroid*.desktop || true
rm -f /usr/share/kservices5/*waydroid* || true
rm -rf /usr/share/waydroid /var/lib/waydroid || true
# Also remove common capitalized filenames
rm -f /usr/share/applications/Waydroid.desktop || true

# QA check: fail the build if any Waydroid desktop/menu files remain
if find /usr/share/applications /usr/local/share/applications /usr/share/kservices5 -maxdepth 2 -type f -iname '*waydroid*' -print -quit | grep -q .; then
	echo "ERROR: Waydroid desktop/menu files remain after cleanup:" >&2
	find /usr/share/applications /usr/local/share/applications /usr/share/kservices5 -maxdepth 2 -type f -iname '*waydroid*' -print >&2 || true
	exit 1
fi

# ── Kyth Helper app — /ctx file installs ──────────────────────────────────────
install -m 0755 /ctx/kyth-welcome/kyth-welcome /usr/bin/kyth-welcome
install -m 0644 /ctx/kyth-welcome/kyth-welcome.desktop \
    /usr/share/applications/kyth-welcome.desktop
install -m 0755 /ctx/game-performance /usr/bin/game-performance
install -m 0755 /ctx/kyth-performance-mode /usr/bin/kyth-performance-mode
install -m 0755 /ctx/zink-run /usr/bin/zink-run
install -m 0755 /ctx/kyth-kerver /usr/bin/kyth-kerver
install -m 0755 /ctx/kyth-device-info /usr/bin/kyth-device-info
install -m 0755 /ctx/kyth-creator-check /usr/bin/kyth-creator-check
install -m 0755 /ctx/kyth-duperemove /usr/bin/kyth-duperemove
install -m 0755 /ctx/kyth-local-bin-migrate /usr/bin/kyth-local-bin-migrate
install -m 0644 /ctx/kyth-duperemove.service /usr/lib/systemd/system/kyth-duperemove.service
install -m 0644 /ctx/kyth-duperemove.timer /usr/lib/systemd/system/kyth-duperemove.timer
install -m 0644 /ctx/kyth-local-bin-migrate.service /usr/lib/systemd/system/kyth-local-bin-migrate.service
install -m 0755 /ctx/kyth-topgrade-migrate        /usr/bin/kyth-topgrade-migrate
install -m 0644 /ctx/kyth-topgrade-migrate.service /usr/lib/systemd/system/kyth-topgrade-migrate.service
install -m 0755 /ctx/kyth-ge-proton-update /usr/bin/kyth-ge-proton-update
install -m 0644 /ctx/kyth-ge-proton-update.service /usr/lib/systemd/system/kyth-ge-proton-update.service
install -m 0644 /ctx/kyth-ge-proton-update.timer /usr/lib/systemd/system/kyth-ge-proton-update.timer
install -m 0644 /ctx/kyth-flathub-setup.service /usr/lib/systemd/system/kyth-flathub-setup.service
install -m 0440 /ctx/kyth-bootc-sudo /etc/sudoers.d/kyth-bootc

# Autostart on first login — removes itself after running once (like kyth-set-resolution).
mkdir -p /etc/skel/.config/autostart
cat > /etc/skel/.config/autostart/kyth-welcome.desktop <<'WELCOMEEOF'
[Desktop Entry]
Type=Application
Name=Kyth Helper
Exec=/usr/bin/kyth-welcome
X-KDE-autostart-after=panel
Hidden=false
NoDisplay=true
WELCOMEEOF

# ── Bootc kernel arguments ────────────────────────────────────────────────────
# Ship quiet + splash so Plymouth shows on the installed system.
# bootc reads kargs.d entries and adds them to the BLS boot entry at install time.
mkdir -p /usr/lib/bootc/kargs.d
cat > /usr/lib/bootc/kargs.d/10-kyth.toml <<'KARGSEOF'
kargs = ["quiet", "splash"]
KARGSEOF

# ── Plymouth boot splash ───────────────────────────────────────────────────────
# Install the Kyth Plymouth theme and rebuild the initramfs so the splash is
# included.  librsvg2-tools provides rsvg-convert to render the logo SVG → PNG.
# plymouth-plugin-script provides the script module used by kyth.plymouth.
dnf5 install -y librsvg2-tools

PLYMOUTH_DIR=/usr/share/plymouth/themes/kyth
mkdir -p "${PLYMOUTH_DIR}"
cp /ctx/plymouth/kyth.plymouth "${PLYMOUTH_DIR}/kyth.plymouth"
cp /ctx/plymouth/kyth.script   "${PLYMOUTH_DIR}/kyth.script"

# Render logo SVG → PNG for Plymouth (Plymouth cannot read SVG natively)
rsvg-convert -w 200 \
    /ctx/calamares/branding/kyth/kyth-logo.svg \
    -o "${PLYMOUTH_DIR}/kyth-logo.png"

plymouth-set-default-theme kyth

# librsvg2-tools was only needed for rsvg-convert above — remove it now
# to keep the final image lean.
dnf5 remove -y librsvg2-tools && dnf5 autoremove -y || true

# Rebuild the initramfs to include Plymouth + the Kyth theme.
# TMPDIR=/var/tmp avoids EXDEV cross-device rename errors.
TMPDIR=/var/tmp dracut \
    --no-hostonly \
    --add "plymouth" \
    --kver "${CACHYOS_KVER}" \
    --force \
    "/usr/lib/modules/${CACHYOS_KVER}/initramfs" \
    2> >(grep -Ev 'xattr|fail to copy' >&2)
echo "Initramfs rebuilt with Plymouth (theme: kyth)"

# ── ujust recipes ─────────────────────────────────────────────────────────────
# Install Kyth-specific ujust recipes so users can run e.g. "ujust rebase kyth:stable".
mkdir -p /usr/share/ublue-os/just
cp /ctx/just/kyth.just /usr/share/ublue-os/just/75-kyth.just
systemctl enable kyth-local-bin-migrate.service 2>/dev/null || true
systemctl enable kyth-topgrade-migrate.service 2>/dev/null || true
systemctl enable kyth-duperemove.timer 2>/dev/null || true
systemctl enable kyth-ge-proton-update.timer 2>/dev/null || true
systemctl enable kyth-flathub-setup.service 2>/dev/null || true

# ── GE-Proton runtime update path ─────────────────────────────────────────────
# The weekly timer installs new GE-Proton to /var/lib/kyth/ge-proton/ (/var is
# writable on an immutable system). Tell Steam to check this path in addition to
# the build-time install in /usr/share/steam/compatibilitytools.d/.
# The directory must exist at first boot — Lutris (and Steam) call os.stat() on
# every path in STEAM_EXTRA_COMPAT_TOOLS_PATHS and crash with FileNotFoundError
# if any are missing, even before the update service has run for the first time.
mkdir -p /var/lib/kyth/ge-proton
echo 'STEAM_EXTRA_COMPAT_TOOLS_PATHS=/var/lib/kyth/ge-proton' > /etc/environment.d/ge-proton.conf
