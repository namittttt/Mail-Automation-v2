#!/bin/bash
set -e
source /opt/mailserver/mailserver.conf

echo "========================================"
echo " Roundcube Configuration (nginx)"
echo "========================================"

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

echo
echo "[1/7] Installing nginx + php-fpm..."
apt update
apt install -y nginx php-fpm

# Detect the installed PHP-FPM socket (version varies by Debian release)
PHP_SOCK=$(find /run/php -name "php*-fpm.sock" | head -n1)
if [ -z "$PHP_SOCK" ]; then
    echo "ERROR: could not find php-fpm socket under /run/php/"
    exit 1
fi
echo "  Using PHP-FPM socket: $PHP_SOCK"

echo
echo "[2/7] Disabling Apache (if installed/running)..."
systemctl stop apache2 2>/dev/null || true
systemctl disable apache2 2>/dev/null || true

echo
echo "[3/7] Configuring Roundcube application config..."
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
echo "[4/7] Writing nginx server block..."
cat > /etc/nginx/sites-available/roundcube.conf <<EOF
server {
    listen 80;
    server_name $MAILHOST;

    root /usr/share/roundcube;
    index index.php;

    access_log /var/log/nginx/roundcube-access.log;
    error_log  /var/log/nginx/roundcube-error.log;

    client_max_body_size 25M;

    location / {
        try_files \$uri \$uri/ /index.php\$is_args\$args;
    }

    location ~ \.php\$ {
        fastcgi_pass unix:$PHP_SOCK;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    # Roundcube ships sensitive dirs that Apache locks via .htaccess;
    # nginx needs these blocked explicitly since it ignores .htaccess.
    location ~ ^/(config|temp|logs|bin|SQL|vendor)/ {
        deny all;
        return 404;
    }

    location ~ /\. {
        deny all;
    }
}
EOF

echo
echo "[5/7] Enabling site..."
ln -sf /etc/nginx/sites-available/roundcube.conf /etc/nginx/sites-enabled/roundcube.conf
rm -f /etc/nginx/sites-enabled/default

echo
echo "[6/7] Testing nginx configuration..."
nginx -t

echo
echo "[7/7] Restarting services..."
systemctl restart php*-fpm
systemctl enable php*-fpm
systemctl restart nginx
systemctl enable nginx

echo
echo "========================================"
echo " Roundcube Configuration Complete (nginx)"
echo "========================================"
echo
echo "Roundcube URL:"
echo "http://$MAILHOST"
