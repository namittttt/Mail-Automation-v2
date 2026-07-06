#!/bin/bash
set -e
source /opt/mailserver/mailserver.conf

echo "========================================"
echo " Postfix Configuration"
echo "========================================"

# ─────────────────────────────────────────────
# [1/9] LDAP lookup — virtual mailbox users
# ─────────────────────────────────────────────
# This file tells Postfix how to verify that a recipient address
# exists. For every incoming message, Postfix queries LDAP with
# filter (mail=%s) — if nothing is returned, the message is
# rejected with "User unknown in virtual mailbox table".
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

# ─────────────────────────────────────────────
# [2/9] LDAP lookup — group aliases
# ─────────────────────────────────────────────
# Groups are stored in ou=groups in LDAP as groupOfNames objects.
# Each group has a 'mail' attribute (e.g. finance@domain.com)
# and 'member' attributes listing member DNs.
# This replaces the old flat /etc/postfix/virtual file for groups.
echo "[2/9] Creating LDAP group alias lookup..."
cat > /etc/postfix/ldap-groups.cf <<EOF
server_host          = 127.0.0.1
search_base          = ou=$GROUP_OU,$BASEDN
query_filter         = (&(objectClass=groupOfNames)(mail=%s))
# member holds DNs like: uid=alice,ou=users,dc=example,dc=com
# leaf_result_attribute extracts the uid value from those DNs
# then result_format rewrites it to an email address
leaf_result_attribute = uid
result_format         = %s@$DOMAIN
bind                  = yes
bind_dn               = $ADMINDN
bind_pw               = $LDAPPASS
EOF
chmod 600 /etc/postfix/ldap-groups.cf

# ─────────────────────────────────────────────
# [3/9] LDAP lookup — sender login map
# ─────────────────────────────────────────────
# This is what enforces sender login mismatch.
# When a user authenticates as 'alice' and tries to send
# FROM: bob@domain.com, Postfix queries this map:
#   "which SASL username is allowed to use bob@domain.com as sender?"
# The map returns 'bob'. The authenticated user is 'alice'.
# They don't match → Postfix rejects with 553.
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

# ─────────────────────────────────────────────
# [4/9] Identity settings
# ─────────────────────────────────────────────
echo "[4/9] Configuring identity..."
postconf -e "myhostname = $MAILHOST"
postconf -e "mydomain   = $DOMAIN"
postconf -e "myorigin   = \$mydomain"
postconf -e "mydestination = localhost"
postconf -e "mynetworks = 127.0.0.0/8"

# ─────────────────────────────────────────────
# [5/9] Virtual domain routing
# ─────────────────────────────────────────────
echo "[5/9] Configuring virtual domains..."
postconf -e "virtual_mailbox_domains = $DOMAIN"
postconf -e "virtual_mailbox_maps    = ldap:/etc/postfix/ldap-users.cf"
# Both LDAP groups and any manual overrides in /etc/postfix/virtual
postconf -e "virtual_alias_maps      = ldap:/etc/postfix/ldap-groups.cf, hash:/etc/postfix/virtual"
touch /etc/postfix/virtual
postmap /etc/postfix/virtual

# vmail uid/gid — all virtual mail is owned by the vmail system user
postconf -e "virtual_uid_maps   = static:5000"
postconf -e "virtual_gid_maps   = static:5000"
postconf -e "virtual_mailbox_base = /var/mail/vhosts"

# ─────────────────────────────────────────────
# [6/9] LMTP delivery to Dovecot
# ─────────────────────────────────────────────
echo "[6/9] Configuring LMTP delivery..."
postconf -e "virtual_transport = lmtp:unix:private/dovecot-lmtp"

# ─────────────────────────────────────────────
# [7/9] TLS configuration
# ─────────────────────────────────────────────
# Opportunistic TLS on port 25 — we try to encrypt inbound connections
# from other mail servers but don't require it (some servers don't support it).
# Self-signed cert used here; replace with Let's Encrypt in production.
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

# ─────────────────────────────────────────────
# [8/9] SASL auth + sender restrictions
# ─────────────────────────────────────────────
# Postfix delegates SASL auth to Dovecot's auth socket.
# Dovecot then checks credentials against LDAP.
echo "[8/9] Configuring SASL + sender restrictions..."
postconf -e "smtpd_sasl_type            = dovecot"
postconf -e "smtpd_sasl_path            = private/auth"
postconf -e "smtpd_sasl_auth_enable     = yes"
postconf -e "smtpd_sasl_security_options= noanonymous"

# smtpd_sender_login_maps: for any given FROM address,
# which SASL username is allowed to use it?
postconf -e "smtpd_sender_login_maps = ldap:/etc/postfix/ldap-sender-login.cf"

# reject_sender_login_mismatch: if the SASL username doesn't match
# what the sender login map says for this FROM address → reject 553
postconf -e "smtpd_sender_restrictions = \
    permit_mynetworks, \
    reject_non_fqdn_sender, \
    reject_unknown_sender_domain, \
    reject_sender_login_mismatch"

# Recipient restrictions
postconf -e "smtpd_recipient_restrictions = \
    permit_mynetworks, \
    permit_sasl_authenticated, \
    reject_non_fqdn_recipient, \
    reject_unknown_recipient_domain, \
    reject_unauth_destination"

# Security hardening
postconf -e "disable_vrfy_command        = yes"
postconf -e "strict_rfc821_envelopes     = yes"
postconf -e "smtpd_helo_required         = yes"
postconf -e "smtpd_helo_restrictions     = reject_invalid_helo_hostname, reject_non_fqdn_helo_hostname"

# Milter — rspamd
postconf -e "smtpd_milters       = inet:localhost:11332"
postconf -e "non_smtpd_milters   = inet:localhost:11332"
postconf -e "milter_protocol     = 6"
postconf -e "milter_default_action = accept"

# ─────────────────────────────────────────────
# [9/9] Submission port 587 in master.cf
# ─────────────────────────────────────────────
# Port 25 is for inbound mail from the internet (MTA to MTA).
# Port 587 is for outbound mail from authenticated users (MUA to MTA).
# Roundcube and email clients should use 587, NOT 25.
#
# Key differences on submission:
#   - TLS is REQUIRED (not optional)
#   - SASL auth is required
#   - reject_sender_login_mismatch enforced here too
#   - Relay is permitted for authenticated users
echo "[9/9] Configuring submission port 587 in master.cf..."

# Safely remove any existing submission block using Python
# (sed range deletion is fragile and can eat other service blocks)
python3 - <<'PYEOF'
import re, sys
with open('/etc/postfix/master.cf', 'r') as f:
    content = f.read()
# Remove the block starting with 'submission inet' up to (not including)
# the next non-comment, non-continuation line
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
  -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject
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
echo " Submission port      : 587 (TLS required)"
echo " Sender mismatch      : enforced on port 25 and 587"
echo " Rspamd milter        : inet:localhost:11332"
