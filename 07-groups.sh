#!/bin/bash
set -e
source /opt/mailserver/mailserver.conf

echo "========================================"
echo " Mail Group Creation (LDAP-backed)"
echo "========================================"

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

# ─────────────────────────────────────────────
# Why LDAP groups instead of a flat file?
# ─────────────────────────────────────────────
# The original script used /etc/postfix/virtual which is a flat hash file.
# That works but means group membership is not in LDAP — you can't list
# "what groups is alice in?" by querying LDAP.
#
# This script creates a proper groupOfNames entry in ou=groups,$BASEDN.
# Postfix queries ldap-groups.cf which reads these entries.
# Members are stored as 'member' attributes pointing to user DNs.

echo
read -p "Group name (e.g. finance, hr, support): " GROUP
GROUP=$(echo "$GROUP" | tr '[:upper:]' '[:lower:]')
ALIAS="${GROUP}@${DOMAIN}"
GROUP_DN="cn=$GROUP,ou=$GROUP_OU,$BASEDN"

echo
echo "Enter member email addresses one by one."
echo "Press Enter with no input when done."
echo

MEMBERS=()
while true; do
    read -p "Member email (or Enter to finish): " MEMBER_EMAIL
    [ -z "$MEMBER_EMAIL" ] && break

    MEMBER_UID=$(echo "$MEMBER_EMAIL" | cut -d'@' -f1)
    MEMBER_DN="uid=$MEMBER_UID,ou=$USER_OU,$BASEDN"

    EXISTS=$(ldapsearch \
        -x -LLL \
        -D "$ADMINDN" -w "$LDAPPASS" \
        -b "ou=$USER_OU,$BASEDN" \
        "(mail=$MEMBER_EMAIL)" dn 2>/dev/null)

    if [ -z "$EXISTS" ]; then
        echo "  WARNING: $MEMBER_EMAIL not found in LDAP — skipping"
    else
        MEMBERS+=("$MEMBER_DN")
        echo "  Added: $MEMBER_EMAIL"
    fi
done

if [ ${#MEMBERS[@]} -eq 0 ]; then
    echo "ERROR: No valid members. Group not created."
    exit 1
fi

echo
echo "Group Summary"
echo "─────────────"
echo "Group alias : $ALIAS"
echo "Group DN    : $GROUP_DN"
echo "Members:"
for m in "${MEMBERS[@]}"; do echo "  $m"; done
echo

read -p "Create group? (y/n): " CONFIRM
[ "$CONFIRM" != "y" ] && { echo "Cancelled."; exit 0; }

EXISTING=$(ldapsearch \
    -x -LLL \
    -D "$ADMINDN" -w "$LDAPPASS" \
    -b "ou=$GROUP_OU,$BASEDN" \
    "(cn=$GROUP)" dn 2>/dev/null)

LDIF_FILE="/tmp/group_${GROUP}_$$.ldif"

if [ -n "$EXISTING" ]; then
    echo
    echo "Group already exists. Updating members..."
    {
        echo "dn: $GROUP_DN"
        echo "changetype: modify"
        echo "replace: member"
        for m in "${MEMBERS[@]}"; do
            echo "member: $m"
        done
    } > "$LDIF_FILE"
    ldapmodify -x -D "$ADMINDN" -w "$LDAPPASS" -f "$LDIF_FILE"
else
    echo
    echo "Creating LDAP group entry..."
    {
        echo "dn: $GROUP_DN"
        echo "objectClass: top"
        echo "objectClass: groupOfNames"
        echo "cn: $GROUP"
        echo "mail: $ALIAS"
        echo "description: Mail group for $GROUP"
        for m in "${MEMBERS[@]}"; do
            echo "member: $m"
        done
    } > "$LDIF_FILE"
    ldapadd -x -D "$ADMINDN" -w "$LDAPPASS" -f "$LDIF_FILE"
fi

rm -f "$LDIF_FILE"

echo
echo "Verifying LDAP group..."
ldapsearch \
    -x -LLL \
    -D "$ADMINDN" -w "$LDAPPASS" \
    -b "ou=$GROUP_OU,$BASEDN" \
    "(cn=$GROUP)" cn mail member

echo
echo "Reloading Postfix..."
postfix check
systemctl reload postfix

echo
echo "========================================"
echo " Group Created Successfully"
echo "========================================"
echo
echo " Alias   : $ALIAS"
echo " Members : ${#MEMBERS[@]} users"
echo
echo " To test the alias:"
echo "   postmap -q $ALIAS ldap:/etc/postfix/ldap-groups.cf"

