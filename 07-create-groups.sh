#!/bin/bash

set -e

source /opt/mailserver/mailserver.conf

echo "========================================"
echo " Mail Group Creation"
echo "========================================"
echo

read -p "Group Name (finance/hr/support): " GROUP

echo
echo "Enter Recipients (comma separated)"
echo "Example:"
echo "lewis@$DOMAIN,max@$DOMAIN"
echo

read -p "Recipients: " RECIPIENTS

ALIAS="${GROUP}@${DOMAIN}"

echo
echo "Alias Summary"
echo "-------------"
echo "Alias      : $ALIAS"
echo "Recipients : $RECIPIENTS"
echo

read -p "Create Alias? (y/n): " CONFIRM

if [ "$CONFIRM" != "y" ]; then
    echo "Cancelled"
    exit 0
fi

grep -v "^${ALIAS}[[:space:]]" \
touch /etc/postfix/virtual

/etc/postfix/virtual > /tmp/virtual.tmp || true

mv /tmp/virtual.tmp /etc/postfix/virtual

echo "${ALIAS} ${RECIPIENTS}" \
>> /etc/postfix/virtual

postmap /etc/postfix/virtual

systemctl restart postfix

echo
echo "Verifying Alias..."

postmap -q "$ALIAS" hash:/etc/postfix/virtual

echo
echo "========================================"
echo " Alias Created Successfully"
echo "========================================"

