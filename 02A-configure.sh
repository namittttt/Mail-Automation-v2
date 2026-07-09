#!/bin/bash

set -e

echo "========================================"
echo " LDAP Configuration"
echo "========================================"

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

# Read domain/password from 01A-install.sh instead of re-prompting.
# Prompting again here risked entering a DIFFERENT domain/password
# than what slapd was actually pre-seeded and initialized with in
# 01A-install.sh, which would just fail with "Can't contact LDAP
# server" or an auth error against a DN that doesn't exist.
if [ -f /opt/mailserver-ldap.tmp ]; then
    source /opt/mailserver-ldap.tmp
else
    echo "ERROR: /opt/mailserver-ldap.tmp not found."
    echo "Run 01A-install.sh first -- it collects the domain and LDAP"
    echo "admin password and pre-seeds slapd with them before install."
    exit 1
fi

FIRST_PART=$(echo "$DOMAIN" | awk -F. '{print $(NF-1)}')
SECOND_PART=$(echo "$DOMAIN" | awk -F. '{print $NF}')

BASEDN="dc=$FIRST_PART,dc=$SECOND_PART"
ADMINDN="cn=admin,$BASEDN"
MAILHOST="mail.$DOMAIN"

USER_OU="users"
GROUP_OU="groups"

echo
echo "Configuration Summary"
echo "---------------------"
echo "Domain     : $DOMAIN"
echo "Hostname   : $MAILHOST"
echo "Base DN    : $BASEDN"
echo "Admin DN   : $ADMINDN"
echo

read -p "Proceed? (y/n): " CONFIRM

if [ "$CONFIRM" != "y" ]; then
    echo "Aborted."
    exit 1
fi

echo
echo "[1/6] Verifying LDAP Login..."

ldapwhoami \
-x \
-D "$ADMINDN" \
-w "$LDAPPASS" >/dev/null

echo "LDAP Login Successful"

echo
echo "[2/6] Checking Base DN..."

if ldapsearch \
-x \
-D "$ADMINDN" \
-w "$LDAPPASS" \
-b "$BASEDN" \
-s base dn >/dev/null 2>&1
then
    echo "Base DN already exists"
else
    echo "Creating Base DN..."

cat > /tmp/base.ldif <<EOF
dn: $BASEDN
objectClass: top
objectClass: dcObject
objectClass: organization

o: $FIRST_PART
dc: $FIRST_PART
EOF

ldapadd \
-x \
-D "$ADMINDN" \
-w "$LDAPPASS" \
-f /tmp/base.ldif

fi

echo
echo "[3/6] Creating Organizational Units..."

cat > /tmp/ou.ldif <<EOF
dn: ou=$USER_OU,$BASEDN
objectClass: organizationalUnit
ou: $USER_OU

dn: ou=$GROUP_OU,$BASEDN
objectClass: organizationalUnit
ou: $GROUP_OU
EOF

ldapadd \
-x \
-D "$ADMINDN" \
-w "$LDAPPASS" \
-f /tmp/ou.ldif || true

echo
echo "[4/6] Creating Configuration Directory..."

mkdir -p /opt/mailserver

echo
echo "[5/6] Saving Configuration..."

RSPAMD_PASSWORD=$(pwgen 16 1)

cat > /opt/mailserver/mailserver.conf <<EOF
DOMAIN=$DOMAIN
MAILHOST=$MAILHOST

BASEDN=$BASEDN
ADMINDN=$ADMINDN

LDAPPASS=$LDAPPASS

RSPAMD_PASSWORD=$RSPAMD_PASSWORD

USER_OU=$USER_OU
GROUP_OU=$GROUP_OU
EOF
chmod 600 /opt/mailserver/mailserver.conf
chown root:root /opt/mailserver/mailserver.conf

# Clean up the temp handoff file now that it's been consumed
rm -f /opt/mailserver-ldap.tmp

echo
echo "[6/6] Verifying LDAP Tree..."

ldapsearch \
-x \
-LLL \
-D "$ADMINDN" \
-w "$LDAPPASS" \
-b "$BASEDN"

echo
echo "========================================"
echo " LDAP Configuration Complete"
echo "========================================"

echo
echo "Configuration Saved:"
echo "/opt/mailserver/mailserver.conf"
