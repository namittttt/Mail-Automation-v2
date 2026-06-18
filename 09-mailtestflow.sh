#!/bin/bash

source /opt/mailserver/mailserver.conf

echo " Mail Flow Test"
echo

read -p "Email Address to Test: " EMAIL

echo
echo "[1/8] LDAP User Lookup"
echo "----------------------"

ldapsearch \
-x \
-LLL \
-D "$ADMINDN" \
-w "$LDAPPASS" \
-b "ou=$USER_OU,$BASEDN" \
"(mail=$EMAIL)" \
uid mail

echo
echo "[2/8] Dovecot User Lookup"
echo "-------------------------"

doveadm user "$EMAIL" || true

echo
echo "[3/8] SMTP Port Check"
echo "---------------------"

ss -tlnp | grep ':25 ' || echo "SMTP Port Not Listening"

echo
echo "[4/8] IMAP Port Check"
echo "---------------------"

ss -tlnp | grep ':143 ' || echo "IMAP Port Not Listening"

echo
echo "[5/8] Mail Queue"
echo "----------------"

mailq

echo
echo "[6/8] Group Aliases"
echo "-------------------"

cat /etc/postfix/virtual

echo
echo "[7/8] LMTP Socket"
echo "-----------------"

if [ -S /var/spool/postfix/private/dovecot-lmtp ]; then
    echo "LMTP Socket Found"
else
    echo "LMTP Socket Missing"
fi

echo
echo "[8/8] Auth Socket"
echo "-----------------"

if [ -S /var/spool/postfix/private/auth ]; then
    echo "Auth Socket Found"
else
    echo "Auth Socket Missing"
fi

echo
echo " Mail Flow Test Complete"

