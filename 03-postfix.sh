#!/bin/bash

set -e

source /opt/mailserver/mailserver.conf

echo "========================================"
echo " Postfix Configuration"
echo "========================================"

echo "[1/6] Creating LDAP Lookup File..."

cat > /etc/postfix/ldap-users.cf <<EOF
server_host = 127.0.0.1

search_base = $BASEDN

query_filter = (mail=%s)

result_attribute = mail

bind = yes

bind_dn = $ADMINDN

bind_pw = $LDAPPASS
EOF

chmod 600 /etc/postfix/ldap-users.cf

echo "[2/6] Configuring Identity..."

postconf -e "myhostname=$MAILHOST"
postconf -e "mydomain=$DOMAIN"
postconf -e "myorigin=\$mydomain"

echo "[3/6] Virtual Domains..."

postconf -e "virtual_mailbox_domains=$DOMAIN"
postconf -e "virtual_mailbox_maps=ldap:/etc/postfix/ldap-users.cf"

echo "[4/6] Alias Maps..."

touch /etc/postfix/virtual
postmap /etc/postfix/virtual

postconf -e "virtual_alias_maps=hash:/etc/postfix/virtual"

echo "[5/6] SMTP Authentication..."

postconf -e "smtpd_sasl_type=dovecot"
postconf -e "smtpd_sasl_path=private/auth"
postconf -e "smtpd_sasl_auth_enable=yes"

postconf -e "smtpd_recipient_restrictions=permit_mynetworks,permit_sasl_authenticated,reject_unauth_destination"

echo "[6/6] LMTP Delivery..."

postconf -e "virtual_transport=lmtp:unix:private/dovecot-lmtp"

postfix check

systemctl restart postfix
systemctl enable postfix

echo
echo "Postfix Configuration Complete"
