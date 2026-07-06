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

if [ -f /opt/mailserver-install.tmp ]; then
    source /opt/mailserver-install.tmp
else
    echo "ERROR: Run 01-install.sh first."
    exit 1
fi

echo
echo "[1/6] Generating DES key..."
DES_KEY=$(pwgen -s 24 1)

echo
echo "[2/6] Writing Roundcube configuration..."
cat > /etc/roundcube/config.inc.php <<EOF
<?php

\$config = [];

/* ---------------- Database ---------------- */

include('/etc/roundcube/debian-db-roundcube.php');

/* ---------------- IMAP ---------------- */

\$config['imap_host'] = 'tls://mail.namit.com:143';

\$config['imap_conn_options'] = [
    'ssl' => [
        'verify_peer'       => false,
        'verify_peer_name'  => false,
        'allow_self_signed' => true,
    ],
];

/* ---------------- SMTP ---------------- */

/*
 * Port 587 = Submission (STARTTLS)
 * Use hostname only. smtp_port tells Roundcube which port to use.
 */

\$config['smtp_host'] = 'tls://mail.namit.com';
\$config['smtp_port'] = 587;

\$config['smtp_user'] = '%u';
\$config['smtp_pass'] = '%p';
\$config['smtp_helo_host'] = 'mail.namit.com';

\$config['smtp_conn_options'] = [
    'ssl' => [
        'verify_peer'       => false,
        'verify_peer_name'  => false,
        'allow_self_signed' => true,
    ],
];

\$config['smtp_timeout'] = 30;

/* ---------------- UI ---------------- */

\$config['product_name'] = 'Mail';
\$config['des_key'] = '${DES_KEY}';

\$config['skin'] = 'elastic';
\$config['language'] = 'en_US';

\$config['enable_spellcheck'] = false;
\$config['quota_zero_as_unlimited'] = false;

/* ---------------- Plugins ---------------- */

/*
 * Disable Sieve plugins until Dovecot IMAPSieve issue is fixed.
 */

\$config['plugins'] = [
    'archive',
    'zipdownload',
];

/* ---------------- Logging ---------------- */

\$config['log_driver'] = 'file';
\$config['debug_level'] = 4;
\$config['smtp_debug'] = true;
\$config['smtp_log'] = true;

EOF


echo
echo "[3/6] Importing Roundcube database..."

if ! mysql roundcube -e "SHOW TABLES;" | grep -q users; then
    mysql roundcube < /usr/share/roundcube/SQL/mysql.initial.sql
fi

echo
echo "[4/6] Configuring Apache..."

cat > /etc/apache2/sites-available/roundcube.conf <<EOF
<VirtualHost *:80>

ServerName mail.namit.com

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
echo "[5/6] Enabling Apache..."

a2enmod rewrite ssl headers >/dev/null
a2ensite roundcube.conf >/dev/null
a2dissite 000-default.conf >/dev/null 2>&1 || true

apache2ctl configtest

echo
echo "[6/6] Restarting Apache..."

systemctl restart apache2
systemctl enable apache2

rm -f /opt/mailserver-install.tmp

echo
echo "========================================"
echo " Roundcube Installed"
echo "========================================"

echo
echo "URL  : http://mail.namit.com"
echo "IMAP : tls://mail.namit.com:143"
echo "SMTP : tls://mail.namit.com:587"
