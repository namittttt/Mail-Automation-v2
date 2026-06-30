#!/bin/bash
set -e
source /opt/mailserver/mailserver.conf

echo "========================================"
echo " Mail Server Security Hardening"
echo "========================================"

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

# ─────────────────────────────────────────────
# [1/7] Fail2ban
# ─────────────────────────────────────────────
# Fail2ban watches log files for repeated failures and bans the
# offending IP using iptables/nftables for a configurable period.
#
# We watch three log files:
#   /var/log/mail.log     → Postfix auth failures (SASL)
#   /var/log/dovecot.log  → Dovecot auth failures (IMAP login)
#   /var/log/apache2/roundcube-error.log → Roundcube brute force
echo "[1/7] Configuring Fail2ban..."
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
# Send email when an IP is banned (optional — needs sendmail)
# destemail = admin@$DOMAIN
# action = %(action_mw)s

[postfix-sasl]
enabled  = true
port     = smtp,submission
filter   = postfix-sasl
logpath  = /var/log/mail.log
maxretry = 5

[dovecot]
enabled  = true
port     = pop3,pop3s,imap,imaps,submission,465,sieve
filter   = dovecot
# Dovecot logs to its own file (set in 04-Dovecot.sh 99-logging.conf)
logpath  = /var/log/dovecot.log
maxretry = 5

[roundcube-auth]
enabled  = true
port     = http,https
filter   = roundcube-auth
logpath  = /var/log/apache2/roundcube-error.log
maxretry = 5
EOF

# Roundcube-specific fail2ban filter
# Matches the log lines Roundcube writes when login fails
cat > /etc/fail2ban/filter.d/roundcube-auth.conf <<EOF
[Definition]
failregex = IMAP Error: Login failed for user .* from <HOST>
            ^.*FAILED login for .* from <HOST>
ignoreregex =
EOF

systemctl enable fail2ban
systemctl restart fail2ban

# ─────────────────────────────────────────────
# [2/7] Rspamd rate limiting (already done in 10-Rspamd.sh)
# ─────────────────────────────────────────────
echo "[2/7] Rate limiting already configured by 10-Rspamd.sh."
echo "      Authenticated users: 30 messages/hour"
echo "      Per-IP: 100 messages/hour"

# ─────────────────────────────────────────────
# [3/7] Greylisting (already done in 10-Rspamd.sh)
# ─────────────────────────────────────────────
echo "[3/7] Greylisting already configured by 10-Rspamd.sh."

# ─────────────────────────────────────────────
# [4/7] RBL (already done correctly in 10-Rspamd.sh)
# ─────────────────────────────────────────────
# NOTE: The original 12-Security.sh wrote rbl.conf in the wrong format.
# The correct rspamd rbl.conf is now written by 10-Rspamd.sh.
# This script no longer touches rbl.conf to avoid overwriting it.
echo "[4/7] RBL already configured correctly by 10-Rspamd.sh."
echo "      Spamhaus ZEN, SpamCop, URIBL enabled."

# ─────────────────────────────────────────────
# [5/7] Postfix hardening
# ─────────────────────────────────────────────
# These settings close common abuse vectors:
#
# disable_vrfy_command: VRFY lets spammers enumerate valid addresses
#   by asking "does alice exist?" without sending mail. Disable it.
#
# strict_rfc821_envelopes: reject malformed envelope addresses
#
# smtpd_helo_required: require HELO/EHLO before MAIL FROM.
#   Spambots often skip this. Legitimate servers always send it.
#
# reject_invalid_helo_hostname: reject HELO with IP literals or
#   syntax errors (e.g. HELO [1.2.3.4] from non-local sender)
#
# reject_non_fqdn_helo_hostname: reject HELO with non-FQDN names
#   (e.g. HELO localhost or HELO mail) — spambot behaviour
#
# reject_non_fqdn_sender/recipient: require proper email addresses
#
# reject_unknown_sender_domain: reject if sender domain has no MX/A record
#   in DNS — these are almost always forged addresses
echo "[5/7] Hardening Postfix..."
postconf -e "disable_vrfy_command        = yes"
postconf -e "strict_rfc821_envelopes     = yes"
postconf -e "smtpd_helo_required         = yes"
postconf -e "smtpd_helo_restrictions     = permit_mynetworks, reject_invalid_helo_hostname, reject_non_fqdn_helo_hostname"
postconf -e "smtpd_sender_restrictions   = permit_mynetworks, reject_non_fqdn_sender, reject_unknown_sender_domain, reject_sender_login_mismatch"
postconf -e "smtpd_recipient_restrictions= permit_mynetworks, permit_sasl_authenticated, reject_non_fqdn_recipient, reject_unknown_recipient_domain, reject_unauth_destination"

# Prevent mail relay abuse
postconf -e "smtpd_relay_restrictions    = permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination"

# Hide server version from banner (security through obscurity — minor but harmless)
postconf -e "smtpd_banner               = \$myhostname ESMTP"

# ─────────────────────────────────────────────
# [6/7] Dovecot hardening
# ─────────────────────────────────────────────
# Enforce TLS for all client connections.
# After this, clients that don't use TLS cannot authenticate at all.
echo "[6/7] Hardening Dovecot..."
# auth_allow_cleartext = no is already set in 04-Dovecot.sh's 10-auth.conf
# ssl = yes is already set in 10-ssl.conf
# Verify both are correct
grep -q "auth_allow_cleartext = no" /etc/dovecot/conf.d/10-auth.conf || \
    sed -i 's/auth_allow_cleartext = yes/auth_allow_cleartext = no/' \
    /etc/dovecot/conf.d/10-auth.conf

# Connection limits — prevent DoS via connection exhaustion
cat >> /etc/dovecot/conf.d/99-auth-sockets.conf <<EOF

service imap-login {
  # Max simultaneous IMAP login processes
  service_count = 1
  process_limit = 256
  # Max connections per IP before refusing
  inet_listener imap {
    port = 143
  }
  inet_listener imaps {
    port = 993
    ssl  = yes
  }
}
EOF

# ─────────────────────────────────────────────
# [7/7] Validate and restart
# ─────────────────────────────────────────────
echo "[7/7] Restarting services and validating..."
rspamadm configtest
postfix check
doveconf -n > /dev/null

systemctl restart postfix
systemctl restart rspamd
systemctl restart dovecot
systemctl restart fail2ban

echo
echo "Fail2ban status:"
fail2ban-client status

echo
echo "Fail2ban jails active:"
fail2ban-client status postfix-sasl 2>/dev/null || true
fail2ban-client status dovecot      2>/dev/null || true

echo
echo "========================================"
echo " Security Hardening Complete"
echo "========================================"
echo
echo " Fail2ban jails   : postfix-sasl, dovecot, roundcube-auth"
echo " Ban threshold    : 5 failures in 10 minutes → 1 hour ban"
echo " Postfix hardening: VRFY disabled, HELO required, FQDN enforced"
echo " Sender mismatch  : enforced (users can only send as their own address)"
echo " RBL              : Spamhaus ZEN + SpamCop + URIBL (via rspamd)"
echo " Rate limiting    : 30 msgs/hr per user, 100 msgs/hr per IP"
echo " Greylisting      : enabled for suspicious senders"
echo " TLS enforcement  : Dovecot requires TLS for all auth"
