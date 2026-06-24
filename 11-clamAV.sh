#!/bin/bash

set -e

source /opt/mailserver/mailserver.conf

echo "========================================"
echo " ClamAV Configuration"
echo "========================================"

if [ "$EUID" -ne 0 ]; then
echo "Please run as root"
exit 1
fi

echo
echo "[1/8] Verifying Installation..."

if ! command -v clamdscan >/dev/null 2>&1; then
echo "ClamAV is not installed."
echo "Run ./01-install.sh first."
exit 1
fi

if ! command -v rspamd >/dev/null 2>&1; then
echo "Rspamd is not installed."
echo "Run ./10-rspamd.sh first."
exit 1
fi

echo "ClamAV Found"
echo "Rspamd Found"

echo
echo "[2/8] Detecting ClamAV Service..."

CLAM_SERVICE=""

if systemctl list-unit-files | grep -q "^clamav-daemon.service"; then
CLAM_SERVICE="clamav-daemon"
elif systemctl list-unit-files | grep -q "^clamd.service"; then
CLAM_SERVICE="clamd"
else
echo "Unable to locate ClamAV service."
exit 1
fi

echo "Detected: $CLAM_SERVICE"

echo
echo "[3/8] Enabling Services..."

systemctl enable "$CLAM_SERVICE"

if systemctl list-unit-files | grep -q "^freshclam.service"; then
systemctl enable freshclam
fi

echo
echo "[4/8] Updating Virus Database..."

if command -v freshclam >/dev/null 2>&1; then
freshclam || true
fi

echo
echo "[5/8] Configuring Rspamd Antivirus Module..."

mkdir -p /etc/rspamd/local.d

cat > /etc/rspamd/local.d/antivirus.conf <<EOF
clamav {
servers = "127.0.0.1:3310";
symbol = "CLAM_VIRUS";
action = "reject";
}
EOF

echo
echo "[6/8] Restarting Services..."

systemctl restart "$CLAM_SERVICE"

if systemctl list-unit-files | grep -q "^freshclam.service"; then
systemctl restart freshclam || true
fi

rspamadm configtest

systemctl restart rspamd

echo
echo "[7/8] Validating Integration..."

echo
echo "ClamAV Status:"
systemctl is-active "$CLAM_SERVICE"

echo
echo "Rspamd Status:"
systemctl is-active rspamd

echo
echo "ClamAV Port:"
ss -tlnp | grep 3310 || true

echo
echo "Rspamd Antivirus Config:"
rspamadm configdump antivirus | head -20 || true

echo
echo "[8/8] Version Information..."

echo
echo "ClamAV:"
clamdscan --version

echo
echo "Freshclam:"
freshclam --version || true

echo
echo "========================================"
echo " ClamAV Configuration Complete"
echo "========================================"

echo
echo "Virus scanning is now integrated with Rspamd."
echo "Infected emails will be rejected automatically."
echo
