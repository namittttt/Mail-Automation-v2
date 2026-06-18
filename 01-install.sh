#!/bin/bash
set -e
echo "========================================"
echo " Mail Server Installation"
echo "========================================"

if [ "$EUID" -ne 0 ]; then
echo "Please run as root"
exit 1
fi

echo
echo "[1/6] Updating Package Repository..."

apt update

echo
echo "[2/6] Installing Required Packages..."

export DEBIAN_FRONTEND=noninteractive

apt install -y \
postfix \
postfix-ldap \
dovecot-core \
dovecot-imapd \
dovecot-pop3d \
dovecot-lmtpd \
dovecot-ldap \
slapd \
ldap-utils \
apache2 \
roundcube \
roundcube-core \
roundcube-mysql \
mariadb-server \
mariadb-client \
php \
php-cli \
php-common \
php-ldap \
php-mysql \
php-imap \
php-mbstring \
php-intl \
php-xml \
php-curl \
php-zip \
pwgen \
mailutils \
telnet

echo
echo "[3/6] Enabling Services..."

systemctl enable slapd
systemctl enable mariadb
systemctl enable postfix
systemctl enable apache2

echo
echo "[4/6] Starting Services..."

systemctl restart slapd
systemctl restart mariadb
systemctl restart postfix
systemctl restart apache2

echo
echo "[5/6] Creating Roundcube Database..."

mysql -e "CREATE DATABASE IF NOT EXISTS roundcube;" || true

echo
echo "[6/6] Verifying Services..."

echo -n "LDAP      : "
systemctl is-active slapd

echo -n "MariaDB   : "
systemctl is-active mariadb

echo -n "Postfix   : "
systemctl is-active postfix

echo -n "Apache2   : "
systemctl is-active apache2

echo
echo "========================================"
echo " Installation Complete"
echo "========================================"

echo
echo "Installed Components:"
echo " - OpenLDAP"
echo " - MariaDB"
echo " - Postfix"
echo " - Dovecot"
echo " - Roundcube"
echo " - Apache2"
echo " - PHP"

