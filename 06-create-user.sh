#!/bin/bash

set -e

source /opt/mailserver/mailserver.conf

echo " LDAP Mail User Creation"
echo

read -p "Username: " USERNAME
read -p "First Name: " FIRSTNAME
read -p "Last Name : " LASTNAME
read -s -p "Password  : " PASSWORD
echo

USERNAME=$(echo "$USERNAME" | tr '[:upper:]' '[:lower:]')

EMAIL="${USERNAME}@${DOMAIN}"

echo
echo "Checking if user already exists..."

EXISTING=$(ldapsearch \
-x \
-LLL \
-D "$ADMINDN" \
-w "$LDAPPASS" \
-b "ou=$USER_OU,$BASEDN" \
"(uid=$USERNAME)" dn)

if [ -n "$EXISTING" ]; then
    echo
    echo "User already exists."
    exit 1
fi

echo
echo "Finding next UID Number..."

LAST_UID=$(ldapsearch \
-x \
-LLL \
-D "$ADMINDN" \
-w "$LDAPPASS" \
-b "ou=$USER_OU,$BASEDN" \
"(uid=*)" uidNumber \
| awk '/uidNumber:/ {print $2}' \
| sort -n \
| tail -1)

if [ -z "$LAST_UID" ]; then
    UIDNUMBER=10000
else
    UIDNUMBER=$((LAST_UID + 1))
fi

HASHED_PASSWORD=$(slappasswd -s "$PASSWORD")

MAILDIR="/var/mail/vhosts/$DOMAIN/$USERNAME"

LDIF_FILE="/tmp/${USERNAME}.ldif"

cat > "$LDIF_FILE" <<EOF
dn: uid=$USERNAME,ou=$USER_OU,$BASEDN
objectClass: top
objectClass: person
objectClass: organizationalPerson
objectClass: inetOrgPerson
objectClass: posixAccount
cn: $FIRSTNAME $LASTNAME
sn: $LASTNAME
uid: $USERNAME
mail: $EMAIL
uidNumber: $UIDNUMBER
gidNumber: 5000
homeDirectory: $MAILDIR
userPassword: $HASHED_PASSWORD
EOF

echo
echo "Generated LDAP Entry"
echo "--------------------"
cat "$LDIF_FILE"

echo
read -p "Create User? (y/n): " CONFIRM

if [ "$CONFIRM" != "y" ]; then
    echo "Cancelled"
    exit 0
fi

ldapadd \
-x \
-D "$ADMINDN" \
-w "$LDAPPASS" \
-f "$LDIF_FILE"

echo
echo "Creating Maildir..."

mkdir -p "$MAILDIR/Maildir"/{cur,new,tmp}

chown -R vmail:vmail "$MAILDIR"

echo
echo "Verifying User..."

ldapsearch \
-x \
-LLL \
-D "$ADMINDN" \
-w "$LDAPPASS" \
-b "ou=$USER_OU,$BASEDN" \
"(uid=$USERNAME)" \
uid mail homeDirectory

echo
echo " User Created Successfully"

echo "Username : $USERNAME"
echo "Email    : $EMAIL"
echo "Maildir  : $MAILDIR/Maildir"

