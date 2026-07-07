#!/bin/bash
set -e

# ─────────────────────────────────────────────────────────────────────
# DEPRECATED — DO NOT USE FOR DOVECOT SIEVE CONFIG
# ─────────────────────────────────────────────────────────────────────
# This script used to write /etc/dovecot/conf.d/20-imap.conf,
# 20-lmtp.conf, and 15-lda.conf. That caused a production outage:
#
#   20-lmtp.conf contained TWO "protocol lmtp { ... }" blocks. The
#   first used the old Dovecot 2.3 string-append syntax:
#
#       protocol lmtp {
#         mail_plugins = $mail_plugins sieve
#       }
#
#   Dovecot 2.4 removed that syntax entirely. Loading it doesn't just
#   warn — every LMTP delivery process crashes on startup with:
#
#       Fatal: Raw user initialization failed:
#       Plugin '$mail_plugins' not found from directory ...
#
#   The process dies before sending even the initial "220" greeting,
#   so from Postfix's side every delivery just shows:
#
#       status=deferred (lost connection ... while receiving the
#       initial server greeting)
#
#   Mail gets accepted by Postfix, queued, and never delivered —
#   with NO error visible in Roundcube or Dovecot's own log, because
#   the crash happens before Dovecot can log anything about it.
#
# Sieve (mail_plugins, imap_sieve, managesieve) is now configured
# ENTIRELY inside 04A-dovecot.sh, using the correct Dovecot 2.4 block
# syntax (mail_plugins { sieve = yes } / imap_sieve = yes), written
# once into 90-sieve.conf, 99-lmtp.conf, and 15-lda equivalents.
#
# This script now only installs packages and the Roundcube managesieve
# plugin config — it no longer touches Dovecot's own conf.d files, so
# it can be re-run safely without reintroducing the crash above.
# ─────────────────────────────────────────────────────────────────────

echo "[1/3] Installing Sieve packages..."
apt install -y dovecot-sieve dovecot-managesieved roundcube-plugins

echo "[2/3] Configuring Roundcube managesieve plugin..."
mkdir -p /var/lib/roundcube/config
cat > /var/lib/roundcube/plugins/managesieve/config.inc.php <<'EOF'
<?php
$config['managesieve_host'] = 'localhost';
EOF

echo "[3/3] NOT touching Dovecot conf.d — that's owned by 04A-dovecot.sh now."
echo "If you need to change Sieve/LMTP/IMAP mail_plugins settings, edit"
echo "04A-dovecot.sh instead of this file."

echo
echo "✓ Sieve packages + Roundcube plugin config complete."
echo "  Run 04A-dovecot.sh (or restart dovecot if already configured) to"
echo "  make sure Dovecot picks up sieve correctly."
