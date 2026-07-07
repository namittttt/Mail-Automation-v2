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

echo "[1/7] Configuring Fail2ban..."

# Fail2ban needs python3-systemd to read the journal directly.
# Debian 13 is journald-first: Postfix logs to the journal, not a
# flat /var/log/mail.log, unless rsyslog is separately installed and
# configured to write one. Rather than depend on that, we read
# straight from the journal for postfix (robust regardless of rsyslog).
apt install -y python3-systemd > /dev/null 2>&1 || true

cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
# destemail = admin@$DOMAIN
# action = %(action_mw)s

[postfix-sasl]
enabled      = true
port         = smtp,submission
filter       = postfix-sasl
backend      = systemd
journalmatch = _SYSTEMD_UNIT=postfix.service
maxretry     = 5

[dovecot]
enabled  = true
port     = pop3,pop3s,imap,imaps,submission,465,sieve
filter   = dovecot
# NOTE: 04A-dovecot.sh sets info_log_path = /var/log/dovecot-info.log.
# Dovecot routes ALL Info-level messages there (including every login
# success/failure) — NOT to log_path (/var/log/dovecot.log), which only
# gets Warning/Error/Fatal. Watching dovecot.log here means this jail
# would NEVER see an auth failure and could never ban anyone. Must
# point at the info log, matching where auth events actually land.
logpath  = /var/log/dovecot-info.log
maxretry = 5

[roundcube-auth]
enabled  = true
port     = http,https
filter   = roundcube-auth
logpath  = /var/log/apache2/roundcube-error.log
maxretry = 5
EOF

cat > /etc/fail2ban/filter.d/roundcube-auth.conf <<EOF
[Definition]
failregex = IMAP Error: Login failed for user .* from <HOST>
            ^.*FAILED login for .* from <HOST>
ignoreregex =
EOF

systemctl enable fail2ban
systemctl restart fail2ban

echo "[2/7] Rate limiting already configured by 10A-Rspamd.sh."
echo "      Authenticated users: 30 messages/hour"
echo "      Per-IP: 100 messages/hour"

echo "[3/7] Greylisting already configured by 10A-Rspamd.sh."

echo "[4/7] RBL already configured correctly by 10A-Rspamd.sh."
echo "      Spamhaus ZEN, SpamCop, URIBL enabled."

echo "[5/7] Hardening Postfix..."
postconf -e "disable_vrfy_command        = yes"
postconf -e "strict_rfc821_envelopes     = yes"
postconf -e "smtpd_helo_required         = yes"
postconf -e "smtpd_helo_restrictions     = permit_mynetworks, reject_invalid_helo_hostname, reject_non_fqdn_helo_hostname"
postconf -e "smtpd_sender_restrictions   = permit_mynetworks, reject_non_fqdn_sender, reject_unknown_sender_domain, reject_sender_login_mismatch"
postconf -e "smtpd_recipient_restrictions= permit_mynetworks, permit_sasl_authenticated, reject_non_fqdn_recipient, reject_unknown_recipient_domain, reject_unauth_destination"
postconf -e "smtpd_relay_restrictions    = permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination"
postconf -e "smtpd_banner               = \$myhostname ESMTP"

echo "[6/7] Hardening Dovecot..."
grep -q "auth_allow_cleartext = no" /etc/dovecot/conf.d/10-auth.conf || \
    sed -i 's/auth_allow_cleartext = yes/auth_allow_cleartext = no/' \
    /etc/dovecot/conf.d/10-auth.conf

cat >> /etc/dovecot/conf.d/99-auth-sockets.conf <<EOF

service imap-login {
  service_count = 1
  process_limit = 256
  inet_listener imap {
    port = 143
  }
  inet_listener imaps {
    port = 993
    ssl  = yes
  }
}
EOF

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
fail2ban-client status roundcube-auth 2>/dev/null || true

echo
echo "========================================"
echo " Security Hardening Complete"
echo "========================================"
echo
echo " Fail2ban jails   : postfix-sasl (journald), dovecot (dovecot-info.log), roundcube-auth"
echo " Ban threshold    : 5 failures in 10 minutes -> 1 hour ban"
echo " Postfix hardening: VRFY disabled, HELO required, FQDN enforced"
echo " Sender mismatch  : enforced (users can only send as their own address)"
echo " RBL              : Spamhaus ZEN + SpamCop + URIBL (via rspamd)"
echo " Rate limiting    : 30 msgs/hr per user, 100 msgs/hr per IP"
echo " Greylisting      : enabled for suspicious senders"
echo " TLS enforcement  : Dovecot requires TLS for all auth"
