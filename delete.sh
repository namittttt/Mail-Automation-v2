#!/bin/bash
set -e

systemctl stop postfix dovecot nginx rspamd clamav-daemon fail2ban redis-server mariadb slapd 2>/dev/null || true

apt purge -y \
    postfix postfix-ldap \
    dovecot-core dovecot-imapd dovecot-pop3d dovecot-lmtpd \
    dovecot-ldap dovecot-sieve dovecot-managesieved \
    nginx nginx-common \
    roundcube roundcube-core roundcube-mysql \
    mariadb-server mariadb-client \
    slapd ldap-utils \
    rspamd \
    clamav clamav-daemon \
    redis-server \
    fail2ban \
    certbot python3-certbot-nginx

apt autoremove -y
apt autoclean

rm -rf /var/mail/vhosts
userdel vmail 2>/dev/null || true
groupdel vmail 2>/dev/null || true

rm -f /opt/mailserver-ldap.tmp
rm -f /opt/mailserver-install.tmp

echo "Cleanup complete."
