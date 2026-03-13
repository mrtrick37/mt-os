# ...existing code...
#!/bin/bash
set -euo pipefail

# Apply mt-OS branding to the base image
cat > /etc/os-release <<'EOF' || true
NAME="mt-OS"
PRETTY_NAME="mt-OS 43"
ID=fedora
VERSION_ID="43"
ANSI_COLOR="0;34"
HOME_URL="https://example.com/mt-os"
SUPPORT_URL="https://example.com/mt-os/support"
BUG_REPORT_URL="https://example.com/mt-os/issues"
EOF

# Remove Waydroid artifacts if present
rm -f /usr/share/applications/*waydroid*.desktop || true
rm -f /usr/local/share/applications/*waydroid*.desktop || true
rm -f /usr/share/kservices5/*waydroid* || true
rm -rf /usr/share/waydroid /var/lib/waydroid || true

echo "mt-OS base customization applied"
