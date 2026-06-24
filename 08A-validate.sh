#!/bin/bash

source /opt/mailserver/mailserver.conf

echo "========================================"
echo " Mail Server Validation"
echo "========================================"
echo

echo "[1/12] Service Status"
echo "---------------------"

echo -n "LDAP      : "
systemctl is-active --quiet slapd && echo "ACTIVE" || echo "FAILED"

echo -n "Postfix   : "
systemctl is-active --quiet postfix && echo "ACTIVE" || echo "FAILED"

echo -n "Dovecot   : "
systemctl is-active --quiet dovecot && echo "ACTIVE" || echo "FAILED"

echo -n "Apache2   : "
systemctl is-active --quiet apache2 && echo "ACTIVE" || echo "FAILED"

echo
echo "[2/12] LDAP Authentication"
echo "--------------------------"

ldapwhoami \
-x \
-D "$ADMINDN" \
-w "$LDAPPASS"

echo
echo "[3/12] LDAP Tree"
echo "----------------"

ldapsearch \
-x \
-LLL \
-D "$ADMINDN" \
-w "$LDAPPASS" \
-b "$BASEDN" dn >/dev/null

echo "LDAP Tree OK"

echo
echo "[4/12] Postfix Configuration"
echo "----------------------------"

postfix check && echo "Postfix Configuration OK"

echo
echo "[5/12] Dovecot Configuration"
echo "----------------------------"

doveconf -n >/dev/null && echo "Dovecot Configuration OK"

echo
echo "[6/12] LDAP Lookup File"
echo "-----------------------"

if [ -f /etc/postfix/ldap-users.cf ]; then
    echo "Found: /etc/postfix/ldap-users.cf"
else
    echo "Missing: /etc/postfix/ldap-users.cf"
fi

echo
echo "[7/12] Virtual Alias File"
echo "--------------------------"

if [ -f /etc/postfix/virtual ]; then
    echo "Found: /etc/postfix/virtual"
else
    echo "Missing: /etc/postfix/virtual"
fi

echo
echo "[8/12] LMTP Socket"
echo "------------------"

if [ -S /var/spool/postfix/private/dovecot-lmtp ]; then
    echo "LMTP Socket Found"
else
    echo "LMTP Socket Missing"
fi

echo
echo "[9/12] Auth Socket"
echo "------------------"

if [ -S /var/spool/postfix/private/auth ]; then
    echo "Auth Socket Found"
else
    echo "Auth Socket Missing"
fi

echo
echo "[10/12] Roundcube Database"
echo "--------------------------"

TABLES=$(mysql -N -B -u root -e "
SELECT COUNT(*)
FROM information_schema.tables
WHERE table_schema='roundcube';
")

if [ "$TABLES" -gt 0 ]; then
    echo "Roundcube Database OK ($TABLES tables)"
else
    echo "Roundcube Database Empty"
fi

echo
echo "[11/12] Roundcube Web Access"
echo "----------------------------"

if curl -s http://127.0.0.1 | grep -qi "Roundcube"; then
    echo "Roundcube Webmail Reachable"
else
    echo "Roundcube Webmail Not Reachable"
fi

echo
echo "[12/12] LDAP Users"
echo "------------------"

USER_COUNT=$(ldapsearch \
-x \
-LLL \
-D "$ADMINDN" \
-w "$LDAPPASS" \
-b "ou=$USER_OU,$BASEDN" \
"(uid=*)" uid \
| grep "^uid:" \
| wc -l)

echo "LDAP Users Found: $USER_COUNT"

echo -n "Rspamd    : "
systemctl is-active --quiet rspamd && echo "ACTIVE" || echo "FAILED"

echo -n "Redis     : "
systemctl is-active --quiet redis-server && echo "ACTIVE" || echo "FAILED"
echo -n "ClamAV    : "

if systemctl is-active --quiet clamav-daemon 2>/dev/null; then
    echo "ACTIVE"
elif systemctl is-active --quiet clamd 2>/dev/null; then
    echo "ACTIVE"
else
    echo "FAILED"
fi

echo
echo "========================================"
echo " Validation Complete"
echo "========================================"
