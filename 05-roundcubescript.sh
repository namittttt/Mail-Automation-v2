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
cat > /etc/roundcube/config.inc.php <<PHPEOF
<?php

\$config = [];

/* ---------------- Database ---------------- */
include('/etc/roundcube/debian-db-roundcube.php');

/* ---------------- IMAP ---------------- */
\$config['imap_host'] = 'tls://$MAILHOST:143';
\$config['imap_conn_options'] = [
    'ssl' => [
        'verify_peer'       => false,
        'verify_peer_name'  => false,
        'allow_self_signed' => true,
    ],
];

/* ---------------- SMTP ---------------- */
// Port 587 = Submission (STARTTLS)
\$config['smtp_host'] = 'tls://$MAILHOST';
\$config['smtp_port'] = 587;
\$config['smtp_user'] = '%u';
\$config['smtp_pass'] = '%p';
\$config['smtp_helo_host'] = '$MAILHOST';
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
\$config['des_key'] = '$DES_KEY';
\$config['skin'] = 'elastic';
\$config['language'] = 'en_US';
\$config['enable_spellcheck'] = false;
\$config['quota_zero_as_unlimited'] = false;

/* ---------------- Plugins ---------------- */
\$config['plugins'] = [
    'archive',
    'zipdownload',
    'managesieve',
    'markasjunk',
];

/* ---------------- Logging ---------------- */
\$config['log_driver'] = 'file';
\$config['debug_level'] = 4;
\$config['smtp_debug'] = true;
\$config['smtp_log'] = true;
PHPEOF

php -l /etc/roundcube/config.inc.php

echo
echo "[3/6] Importing Roundcube database..."

if ! mysql roundcube -e "SHOW TABLES;" | grep -q users; then
    mysql roundcube < /usr/share/roundcube/SQL/mysql.initial.sql
fi

echo
echo "[4/6] Configuring Nginx..."

# Find the actual php-fpm socket (versioned, e.g. php8.4-fpm.sock —
# don't hardcode a PHP version here since it varies by Debian release).
PHP_SOCK=$(find /run/php -name "php*-fpm.sock" 2>/dev/null | head -1)
if [ -z "$PHP_SOCK" ]; then
    echo "ERROR: no php-fpm socket found in /run/php/. Is php-fpm installed and running?"
    exit 1
fi
echo "Using PHP-FPM socket: $PHP_SOCK"

# The rspamd UI reverse-proxy location lives in a separate, optional
# snippet (written by 10A-Rspamd.sh) so the two scripts don't fight
# over the same file, and so this file works fine even if rspamd
# hasn't been configured yet. Create an empty placeholder if missing.
mkdir -p /etc/nginx/snippets
if [ ! -f /etc/nginx/snippets/rspamd-proxy.conf ]; then
    cat > /etc/nginx/snippets/rspamd-proxy.conf <<'EOF'
# Populated by 10A-Rspamd.sh. Empty until that script runs.
EOF
fi

cat > /etc/nginx/sites-available/roundcube.conf <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $MAILHOST;

    root /usr/share/roundcube;
    index index.php;

    access_log /var/log/nginx/roundcube-access.log;
    error_log  /var/log/nginx/roundcube-error.log;

    # Roundcube internals that should never be served directly
    location ~ ^/(config|temp|logs|SQL|bin|installer)/ {
        deny all;
        return 404;
    }
    location ~ /\. {
        deny all;
        return 404;
    }

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:$PHP_SOCK;
    }

    include /etc/nginx/snippets/rspamd-proxy.conf;
}
EOF

ln -sf /etc/nginx/sites-available/roundcube.conf /etc/nginx/sites-enabled/roundcube.conf
rm -f /etc/nginx/sites-enabled/default

echo
echo "[5/6] Validating and enabling Nginx + PHP-FPM..."

nginx -t

PHP_FPM_UNIT=$(systemctl list-unit-files | awk '/^php[0-9.]+-fpm\.service/ {print $1; exit}')
systemctl enable "$PHP_FPM_UNIT"
systemctl restart "$PHP_FPM_UNIT"

echo
echo "[6/6] Restarting Nginx..."

systemctl restart nginx
systemctl enable nginx

rm -f /opt/mailserver-install.tmp

echo
echo "========================================"
echo " Roundcube Installed"
echo "========================================"
echo
echo "URL  : http://$MAILHOST"
echo "IMAP : tls://$MAILHOST:143"
echo "SMTP : tls://$MAILHOST:587"
