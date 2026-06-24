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

echo
echo "[1/7] Configuring Fail2Ban..."

cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5

[dovecot]
enabled = true
port = pop3,pop3s,imap,imaps,submission,465,sieve
logpath = /var/log/dovecot.log

[postfix]
enabled = true
port = smtp,ssmtp,submission
logpath = /var/log/mail.log
EOF

systemctl enable fail2ban
systemctl restart fail2ban

echo
echo "[2/7] Configuring Rspamd Rate Limiting..."

cat > /etc/rspamd/local.d/ratelimit.conf <<EOF
rates {
authenticated = "30 / 1h";
}
EOF

echo
echo "[3/7] Configuring Greylisting..."

cat > /etc/rspamd/local.d/greylist.conf <<EOF
greylist {
enabled = true;
}
EOF

echo
echo "[4/7] Configuring RBL Checks..."

cat > /etc/rspamd/local.d/rbl.conf <<EOF
rbls {
spamhaus {
symbol = "SPAMHAUS";
rbl = "zen.spamhaus.org";
}

spamcop {
symbol = "SPAMCOP";
rbl = "bl.spamcop.net";
}
}
EOF

echo
echo "[5/7] Hardening Postfix..."

postconf -e "disable_vrfy_command = yes"
postconf -e "strict_rfc821_envelopes = yes"
postconf -e "smtpd_helo_required = yes"

postconf -e "smtpd_helo_restrictions = reject_invalid_helo_hostname,reject_non_fqdn_helo_hostname"

postconf -e "smtpd_sender_restrictions = reject_non_fqdn_sender,reject_unknown_sender_domain"

postconf -e "smtpd_recipient_restrictions = reject_non_fqdn_recipient,reject_unknown_recipient_domain"

echo
echo "[6/7] Restarting Services..."

rspamadm configtest

postfix check

systemctl restart postfix
systemctl restart rspamd
systemctl restart fail2ban

echo
echo "[7/7] Validating Security Stack..."

echo
echo "Fail2Ban Status:"
systemctl is-active fail2ban

echo
echo "Rspamd Status:"
systemctl is-active rspamd

echo
echo "Postfix Status:"
systemctl is-active postfix

echo
echo "Fail2Ban Jails:"
fail2ban-client status

echo
echo "Rspamd Config:"
rspamadm configtest

echo
echo "========================================"
echo " Security Hardening Complete"
echo "========================================"

echo
echo "Enabled Features:"
echo " - Fail2Ban"
echo " - Rate Limiting"
echo " - Greylisting"
echo " - Spamhaus RBL"
echo " - SpamCop RBL"
echo " - HELO Validation"
echo " - Sender Validation"
echo " - Recipient Validation"
echo
