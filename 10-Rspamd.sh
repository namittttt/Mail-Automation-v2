#!/bin/bash

set -e

source /opt/mailserver/mailserver.conf

echo "========================================"
echo " Rspamd Configuration"
echo "========================================"

if [ "$EUID" -ne 0 ]; then
echo "Please run as root"
exit 1
fi

if ! command -v rspamd >/dev/null 2>&1; then
echo "Rspamd is not installed."
echo "Run ./01-install.sh first."
exit 1
fi

echo
echo "[1/10] Enabling Services..."

systemctl enable redis-server
systemctl enable rspamd

systemctl restart redis-server

echo
echo "[2/10] Configuring Redis..."

mkdir -p /etc/rspamd/local.d

cat > /etc/rspamd/local.d/redis.conf <<EOF
servers = "127.0.0.1";
EOF

echo
echo "[3/10] Creating DKIM Directory..."

mkdir -p /var/lib/rspamd/dkim

chown -R _rspamd:_rspamd /var/lib/rspamd/dkim 2>/dev/null || true
chmod 750 /var/lib/rspamd/dkim

echo
echo "[4/10] Generating DKIM Keys..."

if [ ! -f /var/lib/rspamd/dkim/mail.key ]; then

```
rspamadm dkim_keygen \
-d "$DOMAIN" \
-s mail \
-k /var/lib/rspamd/dkim/mail.key \
> /var/lib/rspamd/dkim/mail.pub
```

fi

chown -R _rspamd:_rspamd /var/lib/rspamd/dkim 2>/dev/null || true

echo
echo "[5/10] Configuring DKIM Signing..."

cat > /etc/rspamd/local.d/dkim_signing.conf <<EOF
enabled = true;
allow_username_mismatch = true;
path = "/var/lib/rspamd/dkim/$selector.key";
selector = "mail";
sign_authenticated = true;
sign_local = true;

domain {
$DOMAIN {
path = "/var/lib/rspamd/dkim/mail.key";
selector = "mail";
}
}
EOF

echo
echo "[6/10] Enabling SPF / DMARC / ARC..."

cat > /etc/rspamd/local.d/options.inc <<EOF
dns {
timeout = 3s;
}
EOF

cat > /etc/rspamd/local.d/arc.conf <<EOF
enabled = true;
EOF

cat > /etc/rspamd/local.d/dmarc.conf <<EOF
enabled = true;
EOF

echo
echo "[7/10] Configuring Controller UI..."

HASHED_PASS=$(rspamadm pw -p "$RSPAMD_PASSWORD")

cat > /etc/rspamd/local.d/worker-controller.inc <<EOF
bind_socket = "127.0.0.1:11334";

password = "$HASHED_PASS";

enable_password = "$HASHED_PASS";

secure_ip = "127.0.0.1";
EOF

echo
echo "[8/10] Integrating Postfix..."

postconf -e "smtpd_milters = inet:localhost:11332"
postconf -e "non_smtpd_milters = inet:localhost:11332"
postconf -e "milter_protocol = 6"
postconf -e "milter_default_action = accept"

echo
echo "[9/10] Restarting Services..."

rspamadm configtest

systemctl restart rspamd
systemctl restart postfix

echo
echo "[10/10] Validation..."

echo
echo "Rspamd Service"
systemctl is-active rspamd

echo
echo "Redis Service"
systemctl is-active redis-server

echo
echo "Rspamd Milter"
ss -tlnp | grep 11332 || true

echo
echo "Rspamd Controller"
ss -tlnp | grep 11334 || true

echo
echo "========================================"
echo " Rspamd Configuration Complete"
echo "========================================"

echo
echo "Rspamd UI:"
echo "http://127.0.0.1:11334"
echo

echo "Rspamd Password:"
echo "$RSPAMD_PASSWORD"
echo

echo "DKIM DNS Record:"
echo

cat /var/lib/rspamd/dkim/mail.pub

echo
echo "Selector : mail"
echo "Domain   : $DOMAIN"
echo
