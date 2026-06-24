#!/bin/bash

source /opt/mailserver/mailserver.conf

echo "========================================"
echo " Mail Flow Test"
echo "========================================"
echo

read -p "Email Address to Test: " EMAIL

USERNAME=$(echo "$EMAIL" | cut -d'@' -f1)

echo
echo "[1/12] LDAP User Lookup"
echo "----------------------"

ldapsearch \
-x \
-LLL \
-D "$ADMINDN" \
-w "$LDAPPASS" \
-b "ou=$USER_OU,$BASEDN" \
"(mail=$EMAIL)" 
uid mail uidNumber gidNumber homeDirectory

echo
echo "[2/12] Dovecot User Lookup"
echo "-------------------------"

doveadm user "$EMAIL" || true

echo
echo "[3/12] Dovecot Authentication"
echo "-----------------------------"

echo "Run manually if required:"
echo "doveadm auth test $EMAIL"

echo
echo "[4/12] SMTP Port Check"
echo "----------------------"

ss -tlnp | grep ':25 ' || echo "SMTP Port Not Listening"

echo
echo "[5/12] IMAP Port Check"
echo "----------------------"

ss -tlnp | grep ':143 ' || echo "IMAP Port Not Listening"

echo
echo "[6/12] Mail Queue"
echo "-----------------"

mailq

echo
echo "[7/12] Group Aliases"
echo "--------------------"

cat /etc/postfix/virtual 2>/dev/null || echo "No alias file"

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
echo "[10/12] Maildir Check"
echo "---------------------"

MAILDIR="/var/mail/vhosts/$DOMAIN/$USERNAME/Maildir"

if [ -d "$MAILDIR" ]; then
echo "Maildir Found"
ls -ld "$MAILDIR"
else
echo "Maildir Missing"
fi

echo
echo "[11/12] Mail Files"
echo "------------------"

if [ -d "$MAILDIR/new" ]; then
echo "new/: $(find "$MAILDIR/new" -type f | wc -l) messages"
fi

if [ -d "$MAILDIR/cur" ]; then
echo "cur/: $(find "$MAILDIR/cur" -type f | wc -l) messages"
fi
echo -n "Fail2Ban  : "
systemctl is-active --quiet fail2ban && echo "ACTIVE" || echo "FAILED"
echo
echo "[12/12] Recent Dovecot Errors"
echo "-----------------------------"

doveadm log errors 2>/dev/null | tail -10 || true

echo
echo "========================================"
echo " Mail Flow Test Complete"
echo "========================================"
