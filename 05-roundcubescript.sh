#!/bin/bash

set -e

source /opt/mailserver/mailserver.conf

echo "========================================"
echo " Roundcube Configuration"
echo "========================================"

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

echo
echo "[1/8] Configuring Roundcube..."

cat > /etc/roundcube/config.inc.php <<EOF
<?php

\$config = [];

include('/etc/roundcube/debian-db.php');

\$config['imap_host'] = 'localhost:143';

\$config['smtp_host'] = 'localhost:25';

\$config['smtp_user'] = '%u';

\$config['smtp_pass'] = '%p';

\$config['support_url'] = '';

\$config['product_name'] = 'Namit Mail';

\$config['des_key'] = 'voC5fbUK9IgBGAU148NC91ap';

\$config['plugins'] = [];

\$config['skin'] = 'elastic';

\$config['enable_spellcheck'] = false;

\$config['language'] = 'en_US';
EOF

echo
echo "[2/8] Importing Roundcube Database Schema..."

if [ -f /usr/share/roundcube/SQL/mysql.initial.sql ]; then
    mysql -u root roundcube < /usr/share/roundcube/SQL/mysql.initial.sql 2>/dev/null || true
fi

echo
echo "[3/8] Configuring Apache Virtual Host..."

cat > /etc/apache2/sites-available/roundcube.conf <<EOF
<VirtualHost *:80>

    ServerName $MAILHOST

    DocumentRoot /usr/share/roundcube

    <Directory /usr/share/roundcube>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/roundcube-error.log
    CustomLog \${APACHE_LOG_DIR}/roundcube-access.log combined

</VirtualHost>
EOF

echo
echo "[4/8] Enabling Apache Rewrite Module..."

a2enmod rewrite >/dev/null 2>&1 || true

echo
echo "[5/8] Enabling Roundcube Site..."

a2dissite 000-default.conf >/dev/null 2>&1 || true
a2ensite roundcube.conf >/dev/null 2>&1 || true

echo
echo "[6/8] Testing Apache Configuration..."

apache2ctl configtest

echo
echo "[7/8] Restarting Apache..."

systemctl restart apache2
systemctl enable apache2

echo
echo "[8/8] Validating Roundcube..."

curl -I http://127.0.0.1 >/dev/null

echo "Roundcube reachable"

echo
echo "========================================"
echo " Roundcube Configuration Complete"
echo "========================================"

echo
echo "Roundcube URL:"
echo "http://$MAILHOST"
echo "http://127.0.0.1"
echo
