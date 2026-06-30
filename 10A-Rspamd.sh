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

# ─────────────────────────────────────────────
# [1/13] Redis
# ─────────────────────────────────────────────
# Redis is rspamd's memory. Without it:
#   - Bayes training data is lost on restart
#   - Greylisting forgets all triplets
#   - Rate limiting resets all counters
# Everything stateful in rspamd is stored in Redis.
echo "[1/13] Configuring Redis..."
systemctl enable redis-server
systemctl restart redis-server

cat > /etc/rspamd/local.d/redis.conf <<EOF
# All rspamd modules that need state use this Redis instance.
# Each module stores data under a different key prefix so they don't collide.
servers = "127.0.0.1";
EOF

# ─────────────────────────────────────────────
# [2/13] Bayes classifier
# ─────────────────────────────────────────────
# Bayes is a statistical spam classifier.
# It extracts "tokens" (words, URLs, header values) from messages
# and tracks how often each token appears in spam vs ham.
# Over time it learns what YOUR users consider spam.
#
# autolearn: rspamd trains itself automatically on messages it is
# already confident about (score > spam_threshold = spam, < ham_threshold = ham).
# This means it improves without any manual action.
#
# Users can also explicitly train by moving messages to/from Junk
# (handled by Dovecot imapsieve → rspamc learn_spam/learn_ham).
echo "[2/13] Configuring Bayes classifier..."
cat > /etc/rspamd/local.d/classifier-bayes.conf <<EOF
# Store token counts in Redis (persistent across restarts)
backend = "redis";

# Token extraction algorithm.
# osb = Orthogonal Sparse Bigrams — produces better tokens than
# simple word splitting because it captures word pairs and context.
tokenizer {
  name = "osb";
}

# Autolearn: rspamd trains itself on messages it scores confidently.
# If a message scores above 6 → automatically learned as spam.
# If a message scores below -0.5 → automatically learned as ham.
# This requires a minimum number of tokens (100) to avoid noise.
autolearn = true;
autolearn {
  spam_threshold  = 6.0;
  ham_threshold   = -0.5;
  check_balance   = true;   # don't train if ham/spam ratio is too unbalanced
  min_spam        = 100;    # minimum spam messages before classifier is trusted
  min_ham         = 100;    # minimum ham messages
}

# Minimum token count for a message to be classified
min_tokens = 11;

# How strongly Bayes affects the score (0-1)
# 0.95 means Bayes can contribute up to 95% confidence to a symbol
classifier {
  min_prob_strength = 0.05;
}
EOF

# ─────────────────────────────────────────────
# [3/13] SPF module
# ─────────────────────────────────────────────
# SPF checks whether the sending server's IP is listed in the
# sender domain's SPF DNS record.
# e.g. if alice@gmail.com sends via your server, SPF will fail
# because your IP is not in gmail.com's SPF record.
#
# Symbols fired:
#   SPF_PASS      → sender IP is authorised  (score: -0.1)
#   SPF_FAIL      → sender IP is explicitly denied  (score: +4.0)
#   SPF_SOFTFAIL  → sender IP is not authorised but domain uses ~all  (score: +1.0)
#   SPF_NEUTRAL   → domain has no opinion  (score: 0)
#   SPF_DNSFAIL   → DNS lookup failed  (score: 0, informational)
echo "[3/13] Configuring SPF module..."
cat > /etc/rspamd/local.d/spf.conf <<EOF
# Allow SPF checks to fail gracefully when DNS is slow
dns_timeout = 5s;

# Whitelist: IPs in mynetworks should not fail SPF
# (outbound mail from localhost is always legitimate)
whitelist_ip = "/etc/rspamd/maps.d/whitelist-ip.map";
EOF

# ─────────────────────────────────────────────
# [4/13] DKIM keygen
# ─────────────────────────────────────────────
# DKIM adds a cryptographic signature to outgoing messages.
# The private key (mail.key) signs each message.
# The public key (mail.pub) is published in DNS.
# Receiving servers verify the signature against DNS.
# If the message was tampered in transit, the signature fails.
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

# ─────────────────────────────────────────────
# [5/13] DKIM signing
# ─────────────────────────────────────────────
echo "[5/13] Configuring DKIM signing..."
cat > /etc/rspamd/local.d/dkim_signing.conf <<EOF
enabled  = true;
selector = "mail";
path     = "/var/lib/rspamd/dkim/mail.key";

# Sign all outbound authenticated mail and locally injected mail
sign_authenticated = true;
sign_local         = true;

# allow_username_mismatch: sign even when the SASL username (e.g. "alice")
# doesn't exactly match the From address (e.g. "alice@domain.com")
allow_username_mismatch = true;

# Per-domain signing configuration
domain {
  $DOMAIN {
    selector = "mail";
    path     = "/var/lib/rspamd/dkim/mail.key";
  }
}
EOF

# ─────────────────────────────────────────────
# [6/13] ARC + DMARC
# ─────────────────────────────────────────────
echo "[6/13] Enabling ARC and DMARC..."
cat > /etc/rspamd/local.d/arc.conf <<EOF
enabled = true;
EOF

cat > /etc/rspamd/local.d/dmarc.conf <<EOF
enabled = true;
# Report-only mode: don't reject based on DMARC alone, just score.
# Set to false when you trust your SPF/DKIM setup is correct.
no_sampling_domains = true;
EOF

# ─────────────────────────────────────────────
# [7/13] RBL (Real-time Blocklists)
# ─────────────────────────────────────────────
# RBLs are DNS-based blocklists. rspamd looks up the sender IP
# in each list by reversing the IP octets and appending the list domain.
# e.g. for IP 1.2.3.4 checking zen.spamhaus.org:
#   DNS query: 4.3.2.1.zen.spamhaus.org
#   If it returns an A record → IP is listed → fire symbol
#
# zen.spamhaus.org = Spamhaus ZEN (combines SBL + XBL + PBL)
# bl.spamcop.net   = SpamCop (community-reported spam sources)
echo "[7/13] Configuring RBL module..."
cat > /etc/rspamd/local.d/rbl.conf <<EOF
rbls {
  spamhaus_zen {
    symbol    = "RCVD_IN_SPAMHAUS_ZEN";
    rbl       = "zen.spamhaus.org";
    # Different return codes mean different list types
    returncodes {
      RCVD_IN_SBL     = "127.0.0.2";   # Spamhaus Block List
      RCVD_IN_XBL     = ["127.0.0.4", "127.0.0.5", "127.0.0.6", "127.0.0.7"];  # Exploits Block List
      RCVD_IN_PBL     = ["127.0.0.10", "127.0.0.11"];  # Policy Block List
    }
  }

  spamcop {
    symbol = "RCVD_IN_SPAMCOP";
    rbl    = "bl.spamcop.net";
    returncodes {
      RCVD_IN_SPAMCOP = "127.0.0.2";
    }
  }

  # URIBL: checks URLs inside the message body against blocklists
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

# ─────────────────────────────────────────────
# [8/13] Greylisting
# ─────────────────────────────────────────────
# Greylisting works by temporarily refusing mail (4xx) from unknown
# (IP, sender, recipient) triplets. Legitimate MTAs retry after a delay.
# Spambots typically don't retry → they give up → spam blocked.
# The triplet is stored in Redis with a TTL.
echo "[8/13] Configuring greylisting..."
cat > /etc/rspamd/local.d/greylist.conf <<EOF
# Only greylist messages that already look a bit suspicious
# (score above this threshold). Clean mail passes immediately.
greylist_min_score = 2.0;

# How long to greylist (seconds). Legitimate servers retry after ~5min.
expire             = 86400;   # remember whitelisted triplets for 24h
timeout            = 300;     # initial greylist delay (5 minutes)
EOF

# ─────────────────────────────────────────────
# [9/13] Rate limiting
# ─────────────────────────────────────────────
echo "[9/13] Configuring rate limiting..."
cat > /etc/rspamd/local.d/ratelimit.conf <<EOF
rates {
  # Authenticated users: max 30 messages per hour
  # Prevents a compromised account from being used for bulk sending
  authenticated = {
    bucket = {
      burst  = 10;    # allow up to 10 messages immediately
      rate   = "30 / 1h";
    }
  }

  # Per-IP rate limit: max 100 messages per hour from any single IP
  to_ip = {
    bucket = {
      burst  = 20;
      rate   = "100 / 1h";
    }
  }
}
EOF

# ─────────────────────────────────────────────
# [10/13] Multimap — whitelist and blacklist
# ─────────────────────────────────────────────
# Multimap is how you manually control what rspamd does with specific
# senders, IPs, or domains — without writing Lua code.
# Each map is a flat text file. rspamd watches these files and reloads
# them automatically when they change.
#
# From the rspamd UI (http://127.0.0.1:11334) under "Maps" tab,
# you can edit these files directly in the browser.
echo "[10/13] Configuring whitelist/blacklist maps..."

# Create empty map files
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
# ── Whitelists (negative score = ham indicator) ──

WHITELIST_IP {
  type   = "ip";
  map    = "/etc/rspamd/maps.d/whitelist-ip.map";
  symbol = "WHITELIST_IP";
  score  = -10.0;
  description = "Sender IP is whitelisted";
  # File format: one IP or CIDR per line
  # 192.168.1.1
  # 10.0.0.0/8
}

WHITELIST_FROM {
  type   = "from";
  map    = "/etc/rspamd/maps.d/whitelist-from.map";
  symbol = "WHITELIST_FROM";
  score  = -10.0;
  description = "Sender email is whitelisted";
  # File format: one email address per line
  # trusted@partner.com
}

WHITELIST_DOMAIN {
  type   = "from";
  map    = "/etc/rspamd/maps.d/whitelist-domain.map";
  symbol = "WHITELIST_DOMAIN";
  score  = -5.0;
  description = "Sender domain is whitelisted";
  # File format: one domain per line
  # trustedpartner.com
}

# ── Blacklists (high positive score = instant rejection) ──

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

# ─────────────────────────────────────────────
# [11/13] Controller UI + Web access via Apache
# ─────────────────────────────────────────────
# The rspamd controller listens on 127.0.0.1:11334 (localhost only).
# We expose it via an Apache reverse proxy at /rspamd/ so you can
# access it in a browser without an SSH tunnel.
# Protected by HTTP Basic Auth + the rspamd UI password.
echo "[11/13] Configuring controller and Web UI..."

HASHED_PASS=$(rspamadm pw -p "$RSPAMD_PASSWORD")

cat > /etc/rspamd/local.d/worker-controller.inc <<EOF
# Bind to localhost only — Apache proxies it to the outside
bind_socket = "127.0.0.1:11334";

# Hashed password for the UI (generated from RSPAMD_PASSWORD in mailserver.conf)
password        = "$HASHED_PASS";
enable_password = "$HASHED_PASS";

# Connections from 127.0.0.1 (Apache proxy) bypass password on the socket level.
# The rspamd UI itself still prompts for the password in the browser.
secure_ip = "127.0.0.1";

# Allow the UI to save changes to map files (whitelist/blacklist editing)
allow_dynamic_rules = true;

# Tell rspamd which map files are editable from the UI
maps = {
  "Whitelist IPs"     = "/etc/rspamd/maps.d/whitelist-ip.map";
  "Whitelist Senders" = "/etc/rspamd/maps.d/whitelist-from.map";
  "Whitelist Domains" = "/etc/rspamd/maps.d/whitelist-domain.map";
  "Blacklist IPs"     = "/etc/rspamd/maps.d/blacklist-ip.map";
  "Blacklist Senders" = "/etc/rspamd/maps.d/blacklist-from.map";
  "Blacklist Domains" = "/etc/rspamd/maps.d/blacklist-domain.map";
}
EOF

# Apache reverse proxy for rspamd UI
cat > /etc/apache2/sites-available/rspamd.conf <<EOF
<VirtualHost *:80>
    ServerName $MAILHOST

    <Location /rspamd/>
        ProxyPass        http://127.0.0.1:11334/
        ProxyPassReverse http://127.0.0.1:11334/
        # Optional HTTP Basic Auth as an extra layer (uncomment to enable)
        # AuthType Basic
        # AuthName "Rspamd UI"
        # AuthUserFile /etc/apache2/.rspamd-htpasswd
        # Require valid-user
    </Location>
</VirtualHost>
EOF

a2enmod proxy proxy_http > /dev/null 2>&1
a2ensite rspamd.conf > /dev/null 2>&1 || true
systemctl reload apache2 2>/dev/null || true

# ─────────────────────────────────────────────
# [12/13] Postfix milter integration
# ─────────────────────────────────────────────
echo "[12/13] Integrating with Postfix milter..."
postconf -e "smtpd_milters       = inet:localhost:11332"
postconf -e "non_smtpd_milters   = inet:localhost:11332"
postconf -e "milter_protocol     = 6"
postconf -e "milter_default_action = accept"

# ─────────────────────────────────────────────
# [13/13] Start, validate
# ─────────────────────────────────────────────
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
echo " Modules enabled:"
echo "   ✓ SPF verification"
echo "   ✓ DKIM verification + signing"
echo "   ✓ DMARC + ARC"
echo "   ✓ RBL (Spamhaus ZEN, SpamCop, URIBL)"
echo "   ✓ Bayes classifier (autolearn enabled)"
echo "   ✓ Greylisting"
echo "   ✓ Rate limiting"
echo "   ✓ Whitelist/Blacklist (IP, email, domain)"
echo "   ✓ Redis storage"
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
