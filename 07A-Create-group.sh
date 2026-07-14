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
MEMBER_EMAILS=()
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
        echo "  WARNING: $MEMBER_EMAIL not found in LDAP -- skipping"
    else
        MEMBERS+=("$MEMBER_DN")
        MEMBER_EMAILS+=("$MEMBER_EMAIL")
        echo "  Added: $MEMBER_EMAIL"
    fi
done

if [ ${#MEMBERS[@]} -eq 0 ]; then
    echo "ERROR: No valid members. Group not created."
    exit 1
fi

# ─────────────────────────────────────────────
# NEW: Group sending restrictions
# ─────────────────────────────────────────────
# By default anyone can send TO a group alias (same as before). This
# lets you optionally lock a group down so only specific authenticated
# senders can mail it -- e.g. only managers can send to "finance@".
#
# Implemented via Postfix's restriction_class mechanism (the standard,
# documented way to apply different SMTP restrictions to specific
# recipients): https://www.postfix.org/RESTRICTION_CLASS_README.html
#
# NOTE: this is new, not yet battle-tested the way the rest of this
# stack was today -- verify carefully with a real send/reject test
# after creating a restricted group, the same way we verified
# everything else.
echo
read -p "Restrict who can SEND to this group? (y/n): " RESTRICT

RESTRICTED_SENDERS=()
if [ "$RESTRICT" = "y" ]; then
    echo
    echo "Enter allowed sender email addresses one by one."
    echo "Press Enter with no input when done."
    echo
    while true; do
        read -p "Allowed sender email (or Enter to finish): " SENDER_EMAIL
        [ -z "$SENDER_EMAIL" ] && break
        RESTRICTED_SENDERS+=("$SENDER_EMAIL")
        echo "  Allowed: $SENDER_EMAIL"
    done

    if [ ${#RESTRICTED_SENDERS[@]} -eq 0 ]; then
        echo "No senders entered -- group will NOT be restricted."
        RESTRICT="n"
    fi
fi

echo
echo "Group Summary"
echo "-────────────"
echo "Group alias : $ALIAS"
echo "Group DN    : $GROUP_DN"
echo "Members:"
for m in "${MEMBERS[@]}"; do echo "  $m"; done
if [ "$RESTRICT" = "y" ]; then
    echo "Sending restricted to:"
    for s in "${RESTRICTED_SENDERS[@]}"; do echo "  $s"; done
else
    echo "Sending restriction : none (anyone can send to this group)"
fi
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
        # groupOfNames' schema does NOT permit a "mail" attribute --
        # LDAP will reject the entry with "Object class violation:
        # attribute 'mail' not allowed" without this. extensibleObject
        # is a standard core-schema auxiliary class that lifts that
        # restriction, letting any attribute be added regardless of
        # what the structural/other auxiliary classes normally allow.
        echo "objectClass: extensibleObject"
        # qmailGroup requires mail AND mailAlternateAddress AND
        # mailMessageStore (all three, not just mail) -- omitting
        # either of the last two causes an "object class violation:
        # required attribute missing" error. Neither is actually read
        # by Postfix/Dovecot in this setup; they're populated purely
        # to satisfy qmailGroup's schema requirement.
        echo "objectClass: qmailGroup"
        echo "cn: $GROUP"
        echo "mail: $ALIAS"
        # Required by qmailGroup -- not used by Postfix/Dovecot here,
        # just satisfying the schema's MUST list.
        echo "mailAlternateAddress: $ALIAS"
        echo "mailMessageStore: ${mail_base_path:-/var/mail/vhosts}/${DOMAIN}/${GROUP}"
        echo "description: Mail group for $GROUP"
        for m in "${MEMBERS[@]}"; do
            echo "member: $m"
        done
        # rfc822member stores each member as a plain email address
        # (qmailGroup's equivalent of "member", but a string instead
        # of a DN pointer). Kept alongside "member" above rather than
        # replacing it, since Postfix's group expansion (fixed earlier
        # today) relies on the DN-based "member" attribute.
        for email in "${MEMBER_EMAILS[@]}"; do
            echo "rfc822member: $email"
        done
    } > "$LDIF_FILE"
    ldapadd -x -D "$ADMINDN" -w "$LDAPPASS" -f "$LDIF_FILE"
fi

rm -f "$LDIF_FILE"

# ─────────────────────────────────────────────
# Apply the sending restriction, if requested
# ─────────────────────────────────────────────
if [ "$RESTRICT" = "y" ]; then
    echo
    echo "Configuring sender restriction for $ALIAS..."

    mkdir -p /etc/postfix/group-senders
    SENDER_MAP="/etc/postfix/group-senders/${GROUP}.cf"

    : > "$SENDER_MAP"
    for s in "${RESTRICTED_SENDERS[@]}"; do
        echo "$s OK" >> "$SENDER_MAP"
    done
    postmap "$SENDER_MAP"

    CLASS_NAME="grp_${GROUP}"

    # Define the restriction class: only senders in the map above
    # get through for this group; everyone else is rejected.
    postconf -e "${CLASS_NAME} = check_sender_access hash:${SENDER_MAP}, reject"

    # Register the class name in smtpd_restriction_classes, without
    # duplicating it if this group was already restricted before.
    CURRENT_CLASSES=$(postconf -h smtpd_restriction_classes 2>/dev/null || true)
    if ! echo "$CURRENT_CLASSES" | grep -qw "$CLASS_NAME"; then
        if [ -z "$CURRENT_CLASSES" ]; then
            postconf -e "smtpd_restriction_classes = $CLASS_NAME"
        else
            postconf -e "smtpd_restriction_classes = $CURRENT_CLASSES $CLASS_NAME"
        fi
    fi

    # Map this specific recipient address to its restriction class.
    # check_recipient_access only acts on addresses present in this
    # map -- every other address (unrestricted groups, normal users)
    # falls through untouched to the rest of smtpd_recipient_restrictions.
    touch /etc/postfix/restricted-groups
    grep -v "^${ALIAS}[[:space:]]" /etc/postfix/restricted-groups > /tmp/restricted-groups.tmp || true
    mv /tmp/restricted-groups.tmp /etc/postfix/restricted-groups
    echo "${ALIAS} ${CLASS_NAME}" >> /etc/postfix/restricted-groups
    postmap /etc/postfix/restricted-groups

    echo "Restriction applied: only listed senders may mail $ALIAS"
fi

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
if [ "$RESTRICT" = "y" ]; then
    echo " Sending : restricted to ${#RESTRICTED_SENDERS[@]} sender(s)"
else
    echo " Sending : unrestricted"
fi
echo
echo " To test the alias:"
echo "   postmap -q $ALIAS ldap:/etc/postfix/ldap-groups.cf"
if [ "$RESTRICT" = "y" ]; then
    echo " To test the restriction:"
    echo "   postmap -q $ALIAS hash:/etc/postfix/restricted-groups"
    echo "   postmap -q <sender-email> hash:${SENDER_MAP}"
fi
