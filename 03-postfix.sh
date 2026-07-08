#!/bin/bash
set -e
source /opt/mailserver/mailserver.conf

echo "========================================"
echo " Postfix Configuration"
echo "========================================"

echo "[1/9] Creating LDAP user lookup..."
cat > /etc/postfix/ldap-users.cf <<EOF
server_host     = 127.0.0.1
search_base     = ou=$USER_OU,$BASEDN
query_filter    = (mail=%s)
result_attribute= mail
bind            = yes
bind_dn         = $ADMINDN
bind_pw         = $LDAPPASS
EOF
chmod 600 /etc/postfix/ldap-users.cf

echo "[2/9] Creating LDAP group alias lookup..."
cat > /etc/postfix/ldap-groups.cf <<EOF
server_host          = 127.0.0.1
search_base          = ou=$GROUP_OU,$BASEDN
query_filter         = (&(objectClass=groupOfNames)(mail=%s))
leaf_result_attribute = uid
result_format         = %s@$DOMAIN
bind                  = yes
bind_dn               = $ADMINDN
bind_pw               = $LDAPPASS
EOF
chmod 600 /etc/postfix/ldap-groups.cf

echo "[3/9] Creating LDAP sender-login map..."
cat > /etc/postfix/ldap-sender-login.cf <<EOF
server_host     = 127.0.0.1
search_base     = ou=$USER_OU,$BASEDN
query_filter    = (mail=%s)
result_attribute= uid
bind            = yes
bind_dn         = $ADMINDN
bind_pw         = $LDAPPASS
EOF
chmod 600 /etc/postfix/ldap-sender-login.cf

echo "[4/9] Configuring identity..."
postconf -e "myhostname = $MAILHOST"
postconf -e "mydomain   = $DOMAIN"
postconf -e "myorigin   = \$mydomain"
postconf -e "mydestination = localhost"
postconf -e "mynetworks = 127.0.0.0/8"

echo "[5/9] Configuring virtual domains..."
postconf -e "virtual_mailbox_domains = $DOMAIN"
postconf -e "virtual_mailbox_maps    = ldap:/etc/postfix/ldap-users.cf"
postconf -e "virtual_alias_maps      = ldap:/etc/postfix/ldap-groups.cf, hash:/etc/postfix/virtual"
touch /etc/postfix/virtual
postmap /etc/postfix/virtual

postconf -e "virtual_uid_maps   = static:5000"
postconf -e "virtual_gid_maps   = static:5000"
postconf -e "virtual_mailbox_base = /var/mail/vhosts"

echo "[6/9] Configuring LMTP delivery..."
postconf -e "virtual_transport = lmtp:unix:private/dovecot-lmtp"

echo "[7/9] Configuring TLS..."
if [ ! -f /etc/ssl/mail/mail.crt ]; then
    mkdir -p /etc/ssl/mail
    openssl req -new -x509 -days 3650 -nodes \
        -out /etc/ssl/mail/mail.crt \
        -keyout /etc/ssl/mail/mail.key \
        -subj "/CN=$MAILHOST"
    chmod 600 /etc/ssl/mail/mail.key
    chmod 644 /etc/ssl/mail/mail.crt
fi

postconf -e "smtpd_tls_cert_file = /etc/ssl/mail/mail.crt"
postconf -e "smtpd_tls_key_file  = /etc/ssl/mail/mail.key"
postconf -e "smtpd_tls_security_level = may"
postconf -e "smtpd_tls_auth_only = yes"
postconf -e "smtp_tls_security_level = may"
postconf -e "smtpd_tls_loglevel  = 1"
postconf -e "smtpd_tls_received_header = yes"

echo "[8/9] Configuring SASL + sender restrictions..."
postconf -e "smtpd_sasl_type            = dovecot"
postconf -e "smtpd_sasl_path            = private/auth"
postconf -e "smtpd_sasl_auth_enable     = yes"
postconf -e "smtpd_sasl_security_options= noanonymous"

postconf -e "smtpd_sender_login_maps = ldap:/etc/postfix/ldap-sender-login.cf"

postconf -e "smtpd_sender_restrictions = \
    permit_mynetworks, \
    reject_non_fqdn_sender, \
    reject_unknown_sender_domain, \
    reject_sender_login_mismatch"

# NEW: group sending restrictions hook.
# check_recipient_access consults /etc/postfix/restricted-groups (built
# and maintained by 07-groups.sh). It ONLY returns an action for
# recipient addresses actually present in that map -- every other
# address (normal users, unrestricted groups) falls through untouched
# to permit_sasl_authenticated / reject_unauth_destination below,
# exactly as before this feature existed.
# Reference: https://www.postfix.org/RESTRICTION_CLASS_README.html
touch /etc/postfix/restricted-groups
postmap /etc/postfix/restricted-groups

postconf -e "smtpd_recipient_restrictions = \
    permit_mynetworks, \
    permit_sasl_authenticated, \
    reject_non_fqdn_recipient, \
    reject_unknown_recipient_domain, \
    check_recipient_access hash:/etc/postfix/restricted-groups, \
    reject_unauth_destination"

postconf -e "disable_vrfy_command        = yes"
postconf -e "strict_rfc821_envelopes     = yes"
postconf -e "smtpd_helo_required         = yes"
postconf -e "smtpd_helo_restrictions     = reject_invalid_helo_hostname, reject_non_fqdn_helo_hostname"

postconf -e "smtpd_milters       = inet:localhost:11332"
postconf -e "non_smtpd_milters   = inet:localhost:11332"
postconf -e "milter_protocol     = 6"
postconf -e "milter_default_action = accept"

echo "[9/9] Configuring submission port 587 in master.cf..."

python3 - <<'PYEOF'
import re, sys
with open('/etc/postfix/master.cf', 'r') as f:
    content = f.read()
cleaned = re.sub(
    r'\n*^submission\s+inet.*?(?=\n[a-zA-Z#]|\Z)',
    '',
    content,
    flags=re.MULTILINE | re.DOTALL
)
with open('/etc/postfix/master.cf', 'w') as f:
    f.write(cleaned)
print("master.cf cleaned.")
PYEOF

cat >> /etc/postfix/master.cf <<'EOF'

# ── Submission port 587 ─────────────────────────────────────────────
submission inet n       -       y       -       -       smtpd
  -o syslog_name=postfix/submission
  -o smtpd_tls_security_level=encrypt
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_sasl_type=dovecot
  -o smtpd_sasl_path=private/auth
  -o smtpd_sender_login_maps=ldap:/etc/postfix/ldap-sender-login.cf
  -o smtpd_sender_restrictions=reject_non_fqdn_sender,reject_sender_login_mismatch
  -o smtpd_recipient_restrictions=check_recipient_access hash:/etc/postfix/restricted-groups,permit_sasl_authenticated,reject
  -o smtpd_milters=inet:localhost:11332
  -o milter_macro_daemon_name=ORIGINATING
EOF

postfix check
systemctl restart postfix
systemctl enable postfix

echo
echo "========================================"
echo " Postfix Configuration Complete"
echo "========================================"
echo
echo " LDAP user lookup     : /etc/postfix/ldap-users.cf"
echo " LDAP group aliases   : /etc/postfix/ldap-groups.cf"
echo " Sender login map     : /etc/postfix/ldap-sender-login.cf"
echo " Group send restrict  : /etc/postfix/restricted-groups (managed by 07-groups.sh)"
echo " Submission port      : 587 (TLS required)"
echo " Sender mismatch      : enforced on port 25 and 587"
echo " Rspamd milter        : inet:localhost:11332"
