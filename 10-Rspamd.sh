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

echo "[1/14] Configuring Redis..."
systemctl enable redis-server
systemctl restart redis-server

cat > /etc/rspamd/local.d/redis.conf <<EOF
servers = "127.0.0.1";
EOF

echo "[2/14] Configuring Bayes classifier..."
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

echo "[3/14] Configuring SPF module..."
cat > /etc/rspamd/local.d/spf.conf <<EOF
dns_timeout = 5s;
whitelist_ip = "/etc/rspamd/maps.d/whitelist-ip.map";
EOF

echo "[4/14] Generating DKIM keys..."
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

echo "[5/14] Configuring DKIM signing..."
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

echo "[6/14] Enabling ARC and DMARC..."
cat > /etc/rspamd/local.d/arc.conf <<EOF
enabled = true;
EOF

cat > /etc/rspamd/local.d/dmarc.conf <<EOF
enabled = true;
EOF

echo "[7/14] Configuring RBL module..."
cat > /etc/rspamd/local.d/rbl.conf <<EOF
rbls {
  spamhaus_zen {
    symbol    = "RCVD_IN_SPAMHAUS_ZEN";
    rbl       = "zen.spamhaus.org";
    # Explicit check type -- without this, rspamd warns
    # "no check enabled, enable default from check" on every startup.
    checks    = ["from"];
    returncodes {
      RCVD_IN_SBL     = "127.0.0.2";
      RCVD_IN_XBL     = ["127.0.0.4", "127.0.0.5", "127.0.0.6", "127.0.0.7"];
      RCVD_IN_PBL     = ["127.0.0.10", "127.0.0.11"];
    }
  }

  spamcop {
    symbol = "RCVD_IN_SPAMCOP";
    rbl    = "bl.spamcop.net";
    checks = ["from"];
    returncodes {
      RCVD_IN_SPAMCOP = "127.0.0.2";
    }
  }

  # NOTE: a custom uribl_multi block used to live here, duplicating
  # URIBL_BLOCKED/BLACK/GREY/RED -- rspamd's stock rbl module already
  # registers those exact symbol names for multi.uribl.com by default,
  # so ours was silently skipped every startup ("duplicate symbol").
  # Removed as dead code; the built-in rule already covers this.
}
EOF

echo "[8/14] Configuring greylisting..."
cat > /etc/rspamd/local.d/greylist.conf <<EOF
greylist_min_score = 2.0;
expire             = 86400;
timeout            = 300;
EOF

echo "[9/14] Configuring rate limiting..."
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

echo "[10/14] Configuring whitelist/blacklist maps..."
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

echo "[11/14] Configuring ClamAV antivirus integration..."
# IMPORTANT: Debian's clamav-daemon listens on a UNIX SOCKET by default
# (/var/run/clamav/clamd.ctl), NOT a TCP port. "servers = 127.0.0.1:3310"
# silently fails forever -- nothing listens there, so rspamd never gets
# a virus verdict back, with zero error logged anywhere. Verify with:
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

usermod -aG clamav _rspamd 2>/dev/null || usermod -aG clamav rspamd 2>/dev/null || true
systemctl enable clamav-daemon
systemctl restart clamav-daemon

echo "[12/14] Configuring controller and Web UI..."

HASHED_PASS=$(rspamadm pw -p "$RSPAMD_PASSWORD")

cat > /etc/rspamd/local.d/worker-controller.inc <<EOF
bind_socket = "127.0.0.1:11334";
password        = "$HASHED_PASS";
enable_password = "$HASHED_PASS";
secure_ip = "127.0.0.1";
EOF
# NOTE: "allow_dynamic_rules" and "maps" (for in-UI map editing) used to
# be set here but rspamd 4.1.1 doesn't recognize either as controller
# worker attributes -- they were silently ignored every startup
# ("unknown worker attribute"). The whitelist/blacklist .map files are
# still fully functional; just edit them directly on disk instead of
# through the web UI's Maps tab.

# ── Nginx reverse proxy for the Rspamd UI ──
# NOTE: switched from an Apache VirtualHost to an nginx snippet. This is
# NOT a standalone nginx "server {}" block -- nginx will reject two
# separate server{} blocks with the same listen+server_name (it just
# silently drops the second one it parses), which would break either
# this or Roundcube depending on load order. Instead this writes a
# snippet that 05-roundcube.sh's server{} block "include"s, so both
# live inside the same server block safely.
mkdir -p /etc/nginx/snippets
cat > /etc/nginx/snippets/rspamd-proxy.conf <<'EOF'
location /rspamd/ {
    proxy_pass       http://127.0.0.1:11334/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
}
EOF

if nginx -t > /dev/null 2>&1; then
    systemctl reload nginx
else
    echo "WARNING: nginx config test failed -- run 05-roundcube.sh first"
    echo "so the main server block exists, then re-run this script."
fi

echo "[13/14] Integrating with Postfix milter..."
postconf -e "smtpd_milters       = inet:localhost:11332"
postconf -e "non_smtpd_milters   = inet:localhost:11332"
postconf -e "milter_protocol     = 6"
postconf -e "milter_default_action = accept"

echo "[14/14] Starting and validating rspamd..."
rspamadm configtest
systemctl enable rspamd
systemctl restart rspamd
systemctl restart postfix

echo
echo "Rspamd service    : $(systemctl is-active rspamd)"
echo "ClamAV service    : $(systemctl is-active clamav-daemon)"
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
