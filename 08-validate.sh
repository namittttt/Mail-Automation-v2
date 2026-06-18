#!/bin/bash

source /opt/mailserver/mailserver.conf

echo "========================================"
echo " Mail Server Validation"
echo "========================================"
echo

echo "[1/10] Service Status"
echo "---------------------"

echo -n "LDAP      : "
systemctl is-active slapd

echo -n "Postfix   : "
systemctl is-active postfix

echo -n "Dovecot   : "
systemctl is-active dovecot

echo -n "Apache2   : "
systemctl is-active apache2

echo
echo "[2/10] LDAP Authentication"
echo "--------------------------"

ldapwhoami \
-x \
-D "$ADMINDN" \
-w "$LDAPPASS"

echo
echo "[3/10] LDAP Tree"
echo "----------------"

ldapsearch \
-x \
-LLL \
-D "$ADMINDN" \
-w "$LDAPPASS" \
-b "$BASEDN" dn

echo
echo "[4/10] Postfix Configuration"
echo "----------------------------"

postfix check && echo "Postfix Configuration OK"

echo
echo "[5/10] Dovecot Configuration"
echo "----------------------------"

doveconf -n >/dev/null && echo "Dovecot Configuration OK"

echo
echo "[6/10] LDAP Lookup File"
echo "-----------------------"

if [ -f /etc/postfix/ldap-users.cf ]; then
    echo "Found: /etc/postfix/ldap-users.cf"
else
    echo "Missing: /etc/postfix/ldap-users.cf"
fi

echo
echo "[7/10] Virtual Alias File"
echo "--------------------------"

if [ -f /etc/postfix/virtual ]; then
    echo "Found: /etc/postfix/virtual"
else
    echo "Missing: /etc/postfix/virtual"
fi

echo
echo "[8/10] LMTP Socket"
echo "------------------"

if [ -S /var/spool/postfix/private/dovecot-lmtp ]; then
    echo "LMTP Socket Found"
else
    echo "LMTP Socket Missing"
fi

echo
echo "[9/10] Auth Socket"
echo "------------------"

if [ -S /var/spool/postfix/private/auth ]; then
    echo "Auth Socket Found"
else
    echo "Auth Socket Missing"
fi

echo
echo "[10/10] Roundcube"
echo "------------------"

if [ -f /etc/roundcube/config.inc.php ]; then
    echo "Roundcube Config Found"
else
    echo "Roundcube Config Missing"
fi

echo
echo "========================================"
echo " Validation Complete"
echo "========================================"

