#!/bin/bash
set -e

echo "========================================"
echo " Postfix <-> Dovecot SASL Bridge Fix"
echo "========================================"

echo "[1/5] Ensuring submission (587) advertises SASL AUTH..."
# Debian's default master.cf ships the submission block commented out.
# Uncomment it and force the required overrides.
if grep -q "^#submission inet" /etc/postfix/master.cf; then
    sed -i 's/^#submission inet/submission inet/' /etc/postfix/master.cf
fi

# Make sure the override lines exist under submission (idempotent-ish)
if ! grep -q "smtpd_sasl_auth_enable=yes" /etc/postfix/master.cf; then
cat >> /etc/postfix/master.cf <<'EOF'
  -o syslog_name=postfix/submission
  -o smtpd_tls_security_level=may
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_reject_unlisted_recipient=no
  -o smtpd_relay_restrictions=permit_sasl_authenticated,reject
EOF
fi

echo "[2/5] Re-applying core Postfix SASL settings..."
postconf -e "smtpd_sasl_type=dovecot"
postconf -e "smtpd_sasl_path=private/auth"
postconf -e "smtpd_sasl_auth_enable=yes"
postconf -e "smtpd_relay_restrictions=permit_mynetworks,permit_sasl_authenticated,reject"

echo "[3/5] Fully stopping both services (not just reload)..."
systemctl stop postfix
systemctl stop dovecot

echo "[4/5] Removing any stale socket, then starting Dovecot first..."
rm -f /var/spool/postfix/private/auth
systemctl start dovecot
sleep 2

echo "[5/5] Verifying socket, then starting Postfix..."
if [ -S /var/spool/postfix/private/auth ]; then
    echo "  Socket OK: $(ls -l /var/spool/postfix/private/auth)"
else
    echo "  ERROR: Dovecot did not create /var/spool/postfix/private/auth"
    echo "  Check: doveconf -n | grep -A5 'service auth'"
    exit 1
fi

postfix check
systemctl start postfix

echo
echo "Now test directly (bypassing Roundcube):"
echo "  swaks --auth --auth-user 'user@yourdomain' --auth-password 'pass' --to test@yourdomain --server 127.0.0.1:25"
echo
echo "Watch logs in another terminal while testing:"
echo "  tail -f /var/log/mail.log /var/log/dovecot.log"
