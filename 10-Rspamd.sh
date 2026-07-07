#!/bin/bash
set -e
source /opt/mailserver/mailserver.conf

echo "========================================"
echo " Rspamd Configuration"
echo "========================================"

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

if ! command -v rspamd > /dev/null 2>&1; then
    echo "ERROR: rspamd is not installed."
    echo "Run ./01-install.sh first (it adds the official rspamd repo)."
    exit 1
fi

mkdir -p /etc/rspamd/local.d
mkdir -p /etc/rspamd/maps.d

echo "[1/13] Configuring Redis..."
systemctl enable redis-server
systemctl restart redis-server

cat > /etc/rspamd/local.d/redis.conf <<EOF
servers = "127.0.0.1";
EOF

echo "[2/13] Configuring Bayes classifier..."
cat > /etc/rspamd/local.d/classifier-bayes.conf <<EOF
backend = "redis";
tokenizer {
  name = "osb";
}
autolearn = true;
autolearn {
  spam_threshold  = 6.0;
  ham_threshold   = -0.5;
  check_balance   = true;
  min_spam        = 100;
  min_ham         = 100;
}
min_tokens = 11;
classifier {
  min_prob_strength = 0.05;
}
EOF

echo "[3/13] Configuring SPF module..."
cat > /etc/rspamd/local.d/spf.conf <<EOF
dns_timeout = 5s;
whitelist_ip = "/etc/rspamd/maps.d/whitelist-ip.map";
EOF

echo "[4/13] Generating DKIM keys..."
mkdir -p /var/lib/rspamd/dkim
chown -R _rspamd:_rspamd /var/lib/rspamd/dkim 2>/dev/null || \
    chown -R rspamd:rspamd /var/lib/rspamd/dkim 2>/dev/null || true
chmod 750 /var/lib/rspamd/dkim

if [ ! -f /var/lib/rspamd/dkim/mail.key ]; then
    rspamadm dkim_keygen \
        -d "$DOMAIN" \
        -s mail \
        -k /var/lib/rspamd/dkim/mail.key \
        > /var/lib/rspamd/dkim/mail.pub
    chown _rspamd:_rspamd /var/lib/rspamd/dkim/mail.key 2>/dev/null || \
        chown rspamd:rspamd /var/lib/rspamd/dkim/mail.key 2>/dev/null || true
    chmod 640 /var/lib/rspamd/dkim/mail.key
    echo "DKIM key pair generated."
else
    echo "DKIM key already exists, skipping generation."
fi

echo "[5/13] Configuring DKIM signing..."
cat > /etc/rspamd/local.d/dkim_signing.conf <<EOF
enabled  = true;
selector = "mail";
path     = "/var/lib/rspamd/dkim/mail.key";
sign_authenticated = true;
sign_local         = true;
allow_username_mismatch = true;
domain {
  $DOMAIN {
    selector = "mail";
    path     = "/var/lib/rspamd/dkim/mail.key";
  }
}
EOF

echo "[6/13] Enabling ARC and DMARC..."
cat > /etc/rspamd/local.d/arc.conf <<EOF
enabled = true;
EOF

cat > /etc/rspamd/local.d/dmarc.conf <<EOF
enabled = true;
no_sampling_domains = true;
EOF

echo "[7/13] Configuring RBL module..."
cat > /etc/rspamd/local.d/rbl.conf <<EOF
rbls {
  spamhaus_zen {
    symbol    = "RCVD_IN_SPAMHAUS_ZEN";
    rbl       = "zen.spamhaus.org";
    returncodes {
      RCVD_IN_SBL     = "127.0.0.2";
      RCVD_IN_XBL     = ["127.0.0.4", "127.0.0.5", "127.0.0.6", "127.0.0.7"];
      RCVD_IN_PBL     = ["127.0.0.10", "127.0.0.11"];
    }
  }

  spamcop {
    symbol = "RCVD_IN_SPAMCOP";
    rbl    = "bl.spamcop.net";
    returncodes {
      RCVD_IN_SPAMCOP = "127.0.0.2";
    }
  }

  uribl_multi {
    symbol   = "URIBL_BLOCKED";
    rbl      = "multi.uribl.com";
    checks   = ["urls"];
    returncodes {
      URIBL_BLACK  = "127.0.0.2";
      URIBL_GREY   = "127.0.0.4";
      URIBL_RED    = "127.0.0.8";
    }
  }
}
EOF

echo "[8/13] Configuring greylisting..."
cat > /etc/rspamd/local.d/greylist.conf <<EOF
greylist_min_score = 2.0;
expire             = 86400;
timeout            = 300;
EOF

echo "[9/13] Configuring rate limiting..."
cat > /etc/rspamd/local.d/ratelimit.conf <<EOF
rates {
  authenticated = {
    bucket = {
      burst  = 10;
      rate   = "30 / 1h";
    }
  }
  to_ip = {
    bucket = {
      burst  = 20;
      rate   = "100 / 1h";
    }
  }
}
EOF

echo "[10/13] Configuring whitelist/blacklist maps..."
touch /etc/rspamd/maps.d/whitelist-ip.map
touch /etc/rspamd/maps.d/whitelist-from.map
touch /etc/rspamd/maps.d/whitelist-domain.map
touch /etc/rspamd/maps.d/blacklist-ip.map
touch /etc/rspamd/maps.d/blacklist-from.map
touch /etc/rspamd/maps.d/blacklist-domain.map
chown -R _rspamd:_rspamd /etc/rspamd/maps.d 2>/dev/null || \
    chown -R rspamd:rspamd /etc/rspamd/maps.d 2>/dev/null || true
chmod 644 /etc/rspamd/maps.d/*.map

cat > /etc/rspamd/local.d/multimap.conf <<EOF
WHITELIST_IP {
  type   = "ip";
  map    = "/etc/rspamd/maps.d/whitelist-ip.map";
  symbol = "WHITELIST_IP";
  score  = -10.0;
  description = "Sender IP is whitelisted";
}

WHITELIST_FROM {
  type   = "from";
  map    = "/etc/rspamd/maps.d/whitelist-from.map";
  symbol = "WHITELIST_FROM";
  score  = -10.0;
  description = "Sender email is whitelisted";
}

WHITELIST_DOMAIN {
  type   = "from";
  map    = "/etc/rspamd/maps.d/whitelist-domain.map";
  symbol = "WHITELIST_DOMAIN";
  score  = -5.0;
  description = "Sender domain is whitelisted";
}

BLACKLIST_IP {
  type   = "ip";
  map    = "/etc/rspamd/maps.d/blacklist-ip.map";
  symbol = "BLACKLIST_IP";
  score  = 20.0;
  description = "Sender IP is blacklisted";
}

BLACKLIST_FROM {
  type   = "from";
  map    = "/etc/rspamd/maps.d/blacklist-from.map";
  symbol = "BLACKLIST_FROM";
  score  = 20.0;
  description = "Sender email is blacklisted";
}

BLACKLIST_DOMAIN {
  type   = "from";
  map    = "/etc/rspamd/maps.d/blacklist-domain.map";
  symbol = "BLACKLIST_DOMAIN";
  score  = 20.0;
  description = "Sender domain is blacklisted";
}
EOF

echo "[10.5/13] Configuring ClamAV antivirus integration..."
# IMPORTANT: Debian's clamav-daemon listens on a UNIX SOCKET by default
# (/var/run/clamav/clamd.ctl), NOT a TCP port. Pointing this at
# "127.0.0.1:3310" will silently fail forever — nothing listens there,
# so rspamd never gets a virus verdict back, with zero error logged
# anywhere. Verify the actual socket with:
#   ss -tlnp | grep clam        (TCP, only if clamd.conf sets TCPSocket)
#   ls -la /var/run/clamav/     (unix socket, the Debian default)
cat > /etc/rspamd/local.d/antivirus.conf <<EOF
clamav {
  servers = "/var/run/clamav/clamd.ctl";
  symbol  = "CLAM_VIRUS";
  action  = "reject";
  timeout = 15s;
}
EOF

# Make sure rspamd's own user can actually reach the socket
usermod -aG clamav _rspamd 2>/dev/null || usermod -aG clamav rspamd 2>/dev/null || true

systemctl enable clamav-daemon
systemctl restart clamav-daemon

echo "[11/13] Configuring controller and Web UI..."

HASHED_PASS=$(rspamadm pw -p "$RSPAMD_PASSWORD")

cat > /etc/rspamd/local.d/worker-controller.inc <<EOF
bind_socket = "127.0.0.1:11334";
password        = "$HASHED_PASS";
enable_password = "$HASHED_PASS";
secure_ip = "127.0.0.1";
allow_dynamic_rules = true;
maps = {
  "Whitelist IPs"     = "/etc/rspamd/maps.d/whitelist-ip.map";
  "Whitelist Senders" = "/etc/rspamd/maps.d/whitelist-from.map";
  "Whitelist Domains" = "/etc/rspamd/maps.d/whitelist-domain.map";
  "Blacklist IPs"     = "/etc/rspamd/maps.d/blacklist-ip.map";
  "Blacklist Senders" = "/etc/rspamd/maps.d/blacklist-from.map";
  "Blacklist Domains" = "/etc/rspamd/maps.d/blacklist-domain.map";
}
EOF

cat > /etc/apache2/sites-available/rspamd.conf <<EOF
<VirtualHost *:80>
    ServerName $MAILHOST

    <Location /rspamd/>
        ProxyPass        http://127.0.0.1:11334/
        ProxyPassReverse http://127.0.0.1:11334/
    </Location>
</VirtualHost>
EOF

a2enmod proxy proxy_http > /dev/null 2>&1
a2ensite rspamd.conf > /dev/null 2>&1 || true
systemctl reload apache2 2>/dev/null || true

echo "[12/13] Integrating with Postfix milter..."
postconf -e "smtpd_milters       = inet:localhost:11332"
postconf -e "non_smtpd_milters   = inet:localhost:11332"
postconf -e "milter_protocol     = 6"
postconf -e "milter_default_action = accept"

echo "[13/13] Starting and validating rspamd..."
rspamadm configtest
systemctl enable rspamd
systemctl restart rspamd
systemctl restart postfix

echo
echo "Rspamd service    : $(systemctl is-active rspamd)"
echo "Redis service     : $(systemctl is-active redis-server)"
echo "Milter port 11332 : $(ss -tlnp | grep 11332 | awk '{print $1, $4}' || echo 'not listening')"
echo "Controller :11334 : $(ss -tlnp | grep 11334 | awk '{print $1, $4}' || echo 'not listening')"

echo
echo "========================================"
echo " Rspamd Configuration Complete"
echo "========================================"
echo
echo " Web UI            : http://$MAILHOST/rspamd/"
echo " UI Password       : $RSPAMD_PASSWORD"
echo
echo " DKIM DNS record to add:"
echo " ────────────────────────"
cat /var/lib/rspamd/dkim/mail.pub
echo
echo " Selector  : mail"
echo " DNS name  : mail._domainkey.$DOMAIN"
