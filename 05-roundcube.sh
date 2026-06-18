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
echo "[1/5] Configuring Roundcube..."

cat > /etc/roundcube/config.inc.php <<EOF
<?php

\$config = [];

include('/etc/roundcube/debian-db-roundcube.php');

\$config['imap_host'] = 'localhost:143';

\$config['smtp_host'] = 'localhost:25';

\$config['smtp_user'] = '%u';

\$config['smtp_pass'] = '%p';

\$config['support_url'] = '';

\$config['product_name'] = 'Namit Mail';

\$config['des_key'] = 'voC5fbUK9IgBGAU148NC91ap';

\$config['plugins'] = [
    'archive',
    'zipdownload',
];

\$config['skin'] = 'elastic';

\$config['enable_spellcheck'] = false;

\$config['language'] = 'en_US';
EOF

echo
echo "[2/5] Configuring Apache Virtual Host..."

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
echo "[3/5] Enabling Roundcube Site..."

a2ensite roundcube.conf >/dev/null 2>&1 || true

echo
echo "[4/5] Testing Apache Configuration..."

apache2ctl configtest

echo
echo "[5/5] Restarting Apache..."

systemctl restart apache2
systemctl enable apache2

echo
echo "========================================"
echo " Roundcube Configuration Complete"
echo "========================================"

echo
echo "Roundcube URL:"
echo "http://$MAILHOST"
