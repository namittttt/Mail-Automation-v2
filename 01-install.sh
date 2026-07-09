#!/bin/bash
set -e

echo "========================================"
echo " Mail Server Installation"
echo "========================================"

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

# ─────────────────────────────────────────────
# [0/9] Collect domain + LDAP admin password FIRST
# ─────────────────────────────────────────────
# slapd needs these answers via debconf BEFORE it's installed, or its
# postinst never generates a working /etc/ldap/slapd.d config at all --
# it just fails on every subsequent start with:
#   could not stat config file "/etc/ldap/slapd.conf": No such file
# Reconfiguring slapd AFTER an unseeded install (dpkg-reconfigure) is
# unreliable on current Debian/Ubuntu releases (confirmed independently
# by multiple sources) -- pre-seeding before the initial install is the
# only approach that reliably works.
echo
read -p "Domain Name (example: namit.com): " DOMAIN
DOMAIN=$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]')
FIRST_PART=$(echo "$DOMAIN" | awk -F. '{print $(NF-1)}')
SECOND_PART=$(echo "$DOMAIN" | awk -F. '{print $NF}')
BASEDN="dc=$FIRST_PART,dc=$SECOND_PART"

echo
read -s -p "LDAP Admin Password: " LDAPPASS
echo

# Save for 02-configure.sh so it doesn't have to re-prompt (and risk
# a mismatched domain/password from what slapd is actually seeded with)
mkdir -p /opt/mailserver
cat > /opt/mailserver-ldap.tmp <<EOF
DOMAIN=$DOMAIN
LDAPPASS=$LDAPPASS
EOF
chmod 600 /opt/mailserver-ldap.tmp

echo
echo "[1/9] Updating Package Repository..."
apt update

echo
echo "[2/9] Installing Core Dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt install -y \
    curl \
    gnupg2 \
    lsb-release \
    ca-certificates \
    apt-transport-https

echo
echo "[3/9] Adding Rspamd Official Repository..."
curl -fsSL https://rspamd.com/apt-stable/gpg.key \
    | gpg --dearmor \
    | tee /usr/share/keyrings/rspamd.gpg > /dev/null

echo "deb [signed-by=/usr/share/keyrings/rspamd.gpg] \
https://rspamd.com/apt-stable/ $(lsb_release -cs) main" \
    > /etc/apt/sources.list.d/rspamd.list

apt update

echo
echo "[3.5/9] Pre-seeding slapd (must happen BEFORE it's installed)..."
debconf-set-selections <<EOF
slapd slapd/password1 password $LDAPPASS
slapd slapd/password2 password $LDAPPASS
slapd slapd/internal/adminpw password $LDAPPASS
slapd slapd/internal/generated_adminpw password $LDAPPASS
slapd slapd/domain string $DOMAIN
slapd shared/organization string $DOMAIN
slapd slapd/backend select MDB
slapd slapd/purge_database boolean true
slapd slapd/move_old_database boolean true
slapd slapd/allow_ldap_v2 boolean false
slapd slapd/no_configuration boolean false
EOF

echo
echo "[4/9] Installing Mail Server Packages..."
apt install -y \
    postfix \
    postfix-ldap \
    dovecot-core \
    dovecot-imapd \
    dovecot-pop3d \
    dovecot-lmtpd \
    dovecot-ldap \
    dovecot-sieve \
    dovecot-managesieved \
    slapd \
    ldap-utils \
    nginx \
    roundcube \
    roundcube-core \
    roundcube-mysql \
    mariadb-server \
    mariadb-client \
    php \
    php-fpm \
    php-cli \
    php-common \
    php-ldap \
    php-mysql \
    php-mbstring \
    php-intl \
    php-xml \
    php-curl \
    php-zip \
    pwgen \
    mailutils \
    redis-server \
    rspamd \
    clamav \
    clamav-daemon \
    fail2ban \
    telnet \
    certbot \
    python3-certbot-nginx \
    python3-systemd \
    openssl

echo
echo "[5/9] Enabling Services at Boot..."
systemctl enable slapd
systemctl enable mariadb
systemctl enable postfix
systemctl enable nginx
PHP_FPM_UNIT=$(systemctl list-unit-files | awk '/^php[0-9.]+-fpm\.service/ {print $1; exit}')
systemctl enable "$PHP_FPM_UNIT"
systemctl enable dovecot
systemctl enable redis-server
systemctl enable rspamd
systemctl enable fail2ban

echo
echo "[6/9] Starting Services..."
systemctl restart slapd
systemctl restart mariadb
systemctl restart postfix
systemctl restart "$PHP_FPM_UNIT"
systemctl restart nginx
systemctl restart dovecot
systemctl restart redis-server

echo
echo "Verifying slapd was actually initialized correctly..."
if ldapwhoami -x -D "cn=admin,$BASEDN" -w "$LDAPPASS" > /dev/null 2>&1; then
    echo "slapd OK -- admin bind succeeded for cn=admin,$BASEDN"
else
    echo "ERROR: slapd did not initialize correctly. This should not"
    echo "happen with pre-seeding in place -- check:"
    echo "  systemctl status slapd"
    echo "  journalctl -xeu slapd.service"
    echo "  ls -la /etc/ldap/slapd.d/"
    exit 1
fi

echo
echo "[7/9] Creating Roundcube Database..."
RC_DB_PASS=$(pwgen 20 1)

mysql <<EOF
CREATE DATABASE IF NOT EXISTS roundcube CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'roundcube'@'localhost' IDENTIFIED BY '${RC_DB_PASS}';
GRANT ALL PRIVILEGES ON roundcube.* TO 'roundcube'@'localhost';
FLUSH PRIVILEGES;
EOF

echo "RC_DB_PASS=${RC_DB_PASS}" > /opt/mailserver-install.tmp
chmod 600 /opt/mailserver-install.tmp

echo
echo "[8/9] Creating vmail System User..."
# IMPORTANT: every other script (03A-postfix.sh's virtual_uid_maps/
# virtual_gid_maps, 04A-dovecot.sh's userdb, this file) assumes vmail
# is uid/gid 5000. If ANYTHING on this box already created a "vmail"
# group/user before this point, the guards below silently skip
# creation and vmail ends up with whatever ID that other thing picked.
# Verify after running:  id vmail   -> must show uid=5000(vmail) gid=5000(vmail)
if ! getent group vmail > /dev/null 2>&1; then
    groupadd -g 5000 vmail
fi
if ! id vmail > /dev/null 2>&1; then
    useradd -r -g vmail -u 5000 -d /var/mail/vhosts \
        -s /usr/sbin/nologin vmail
fi
mkdir -p /var/mail/vhosts
chown -R vmail:vmail /var/mail/vhosts
chmod 750 /var/mail/vhosts
chmod 711 /var/mail

echo
echo "[9/9] Verifying Services..."
echo -n "LDAP     : "; systemctl is-active slapd
echo -n "MariaDB  : "; systemctl is-active mariadb
echo -n "Postfix  : "; systemctl is-active postfix
echo -n "Nginx    : "; systemctl is-active nginx
echo -n "PHP-FPM  : "; systemctl is-active "$PHP_FPM_UNIT"
echo -n "Dovecot  : "; systemctl is-active dovecot
echo -n "Redis    : "; systemctl is-active redis-server
echo -n "vmail id : "; id vmail

echo
echo "========================================"
echo " Installation Complete"
echo "========================================"
echo
echo "Installed Components:"
echo " - OpenLDAP (slapd + ldap-utils) -- pre-seeded and verified"
echo " - MariaDB"
echo " - Postfix + postfix-ldap"
echo " - Dovecot (IMAP + LMTP + LDAP + Sieve + ManageSieve + imapsieve)"
echo " - Roundcube webmail"
echo " - Nginx + PHP-FPM"
echo " - Redis"
echo " - Rspamd"
echo " - ClamAV"
echo " - Fail2ban"
echo " - Certbot (nginx plugin)"
echo
echo "Domain/LDAP password saved to /opt/mailserver-ldap.tmp"
echo "This file is read by 02-configure.sh and deleted after use."
echo "Roundcube DB password saved to /opt/mailserver-install.tmp"
echo "This file is read by 05-roundcube.sh and deleted after use."
