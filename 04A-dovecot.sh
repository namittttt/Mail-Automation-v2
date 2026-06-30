#!/bin/bash
set -e
source /opt/mailserver/mailserver.conf

echo "========================================"
echo " Dovecot Configuration"
echo "========================================"

VMAIL_UID=5000
VMAIL_GID=5000

# ─────────────────────────────────────────────
# [1/11] Mail storage directory
# ─────────────────────────────────────────────
echo "[1/11] Creating mail storage..."
mkdir -p /var/mail/vhosts/$DOMAIN
chown -R vmail:vmail /var/mail/vhosts
chmod 750 /var/mail/vhosts

# ─────────────────────────────────────────────
# [2/11] TLS — self-signed cert
# ─────────────────────────────────────────────
# Dovecot needs TLS so that IMAP credentials are not sent in plaintext.
# Port 993 = IMAPS (TLS from the start)
# Port 143 with STARTTLS = upgrade to TLS mid-connection
# We use the same cert as Postfix here. Replace with Let's Encrypt
# cert in production by updating ssl_cert and ssl_key paths.
echo "[2/11] Configuring TLS..."
cat > /etc/dovecot/conf.d/10-ssl.conf <<EOF
ssl = yes
ssl_cert = </etc/ssl/mail/mail.crt
ssl_key  = </etc/ssl/mail/mail.key
ssl_min_protocol = TLSv1.2
# Disable cleartext auth over non-TLS connections.
# With this set, plaintext passwords are only allowed over TLS.
EOF

# ─────────────────────────────────────────────
# [3/11] LDAP authentication (passdb + userdb)
# ─────────────────────────────────────────────
# passdb   = answers "is this password correct?"
# userdb   = answers "where is this user's mail stored?"
# Both use LDAP. The filter finds users by uid attribute.
# homeDirectory from LDAP tells Dovecot where Maildir lives.
echo "[3/11] Configuring LDAP auth..."
cat > /etc/dovecot/conf.d/auth-ldap.conf.ext <<EOF
ldap_uris           = ldap://localhost
ldap_auth_dn        = $ADMINDN
ldap_auth_dn_password = $LDAPPASS
ldap_base           = $BASEDN

# passdb: verify password
passdb ldap {
  ldap_filter = (&(objectClass=posixAccount)(uid=%{user}))
  ldap_bind   = no
  fields {
    user              = %{ldap:uid}
    password          = %{ldap:userPassword}
    userdb_home       = %{ldap:homeDirectory}
    userdb_uid        = %{ldap:uidNumber}
    userdb_gid        = %{ldap:gidNumber}
    userdb_quota_rule = *:bytes=%{ldap:mailQuota}
  }
}

# userdb: get mailbox location and uid/gid for mail delivery
userdb ldap {
  filter = (&(objectClass=posixAccount)(uid=%{user}))
  fields {
    home       = %{ldap:homeDirectory}
    uid        = %{ldap:uidNumber}
    gid        = %{ldap:gidNumber}
    quota_rule = *:bytes=%{ldap:mailQuota}
  }
}
EOF

# ─────────────────────────────────────────────
# [4/11] Master user
# ─────────────────────────────────────────────
# A master user can log in as any other user without knowing their password.
# Login syntax: alice*mailadmin  (user*masteruser)
# This is essential for: admin mailbox inspection, migration, debugging.
# The master user credentials are in a separate flat file (not LDAP)
# so they work even if LDAP is down.
echo "[4/11] Configuring master user..."

MASTER_PASS=$(pwgen 24 1)
MASTER_HASH=$(doveadm pw -s SSHA512 -p "$MASTER_PASS" 2>/dev/null || \
              doveadm pw -s SHA512-CRYPT -p "$MASTER_PASS")

mkdir -p /etc/dovecot/private
cat > /etc/dovecot/private/master-users <<EOF
mailadmin:$MASTER_HASH
EOF
chmod 600 /etc/dovecot/private/master-users

# Save master password to mailserver.conf for reference
echo "MASTER_USER=mailadmin" >> /opt/mailserver/mailserver.conf
echo "MASTER_PASS=$MASTER_PASS" >> /opt/mailserver/mailserver.conf

cat > /etc/dovecot/conf.d/auth-master.conf.ext <<EOF
# Master users are looked up from a flat passwd-file.
# The passdb below runs ONLY when the login contains the * separator.
passdb passwd-file {
  master = yes
  passwd_file = /etc/dovecot/private/master-users
}
EOF

# ─────────────────────────────────────────────
# [5/11] Auth mechanisms + auth config
# ─────────────────────────────────────────────
echo "[5/11] Configuring auth mechanisms..."
cat > /etc/dovecot/conf.d/10-auth.conf <<EOF
# Never allow plaintext auth over non-TLS connections.
auth_allow_cleartext = no

# PLAIN and LOGIN are the standard mechanisms used by email clients.
# They're safe over TLS. Do not add CRAM-MD5 — it doesn't work with LDAP.
auth_mechanisms = plain login

# auth_master_user_separator: the character that separates the real
# user from the master user in the login string.
# alice*mailadmin → logs in as alice using mailadmin's credentials
auth_master_user_separator = *

!include auth-ldap.conf.ext
!include auth-master.conf.ext
EOF

# ─────────────────────────────────────────────
# [6/11] Mail storage (Maildir)
# ─────────────────────────────────────────────
# mail_path = ~/Maildir
# ~ expands to homeDirectory from LDAP = /var/mail/vhosts/domain/username
# So alice's mail lives at /var/mail/vhosts/example.com/alice/Maildir/
echo "[6/11] Configuring mail storage..."
cat > /etc/dovecot/conf.d/10-mail.conf <<EOF
mail_driver           = maildir
mail_path             = ~/Maildir
mail_privileged_group = mail

# These plugins are loaded for all mail access.
mail_plugins          = \$mail_plugins quota
EOF

# ─────────────────────────────────────────────
# [7/11] Quota
# ─────────────────────────────────────────────
# Quota is enforced at two levels:
#   1. Dovecot: refuses IMAP operations (e.g. copy) when over quota
#   2. Postfix quota-status: checks quota BEFORE delivery so Postfix
#      returns a 452 to the sending server instead of accepting+bouncing
#
# mailQuota comes from the LDAP user entry (added in 06-create-user.sh).
# Default quota is 1GB if the LDAP attribute is missing.
echo "[7/11] Configuring quota..."
cat > /etc/dovecot/conf.d/90-quota.conf <<EOF
plugin {
  # Default quota if not set in LDAP
  quota_rule = *:storage=1G

  # Quota exceeded warning at 90%
  quota_warning = storage=90%% quota-warning 90 %u
  quota_warning2= storage=100%% quota-warning 100 %u
}

# quota-status service: Postfix queries this before accepting a message.
# It listens on a unix socket and Postfix checks "is this user over quota?"
service quota-status {
  executable = quota-status -p postfix
  inet_listener {
    port = 12340
  }
}

# Warning script — sends an email to the user when quota is near full
service quota-warning {
  executable = script /usr/local/bin/quota-warning.sh
  unix_listener quota-warning {
    user = vmail
    mode = 0600
  }
}
EOF

# Quota warning script
# Note: we write $DOMAIN as a literal \$DOMAIN here because this script
# runs standalone later — it reads DOMAIN from mailserver.conf at runtime.
cat > /usr/local/bin/quota-warning.sh <<SCRIPT
#!/bin/bash
source /opt/mailserver/mailserver.conf
PERCENT=\$1
USER=\$2
printf "From: postmaster@\${DOMAIN}\nTo: \${USER}\nSubject: Mailbox quota warning: \${PERCENT}%% used\n\nYour mailbox is \${PERCENT}%% full.\nPlease delete old messages or contact your administrator.\n" \
    | sendmail -f "postmaster@\${DOMAIN}" "\${USER}"
SCRIPT
chmod +x /usr/local/bin/quota-warning.sh

# Tell Postfix to check quota before delivery
postconf -e "smtpd_end_of_data_restrictions = check_policy_service inet:localhost:12340"

# ─────────────────────────────────────────────
# [8/11] Sieve filters
# ─────────────────────────────────────────────
# Sieve is a mail filtering language. Users write rules like:
#   "if subject contains [SPAM] then file into Junk"
# ManageSieve (port 4190) lets email clients upload/manage these scripts.
#
# sieve = path to the user's active sieve script
# sieve_global = server-wide scripts that run for ALL users
#                (used for spam reporting — see step 9)
echo "[8/11] Configuring Sieve..."
mkdir -p /etc/dovecot/sieve/global
cat > /etc/dovecot/conf.d/90-sieve.conf <<EOF
plugin {
  # User's personal sieve scripts directory
  sieve = file:~/sieve;active=~/.dovecot.sieve

  # Global scripts: run for every user (before personal scripts)
  sieve_global = /etc/dovecot/sieve/global/

  # ManageSieve: lets email clients manage sieve scripts remotely
  sieve_plugins = sieve_imapsieve sieve_extprograms

  # imapsieve: fire sieve scripts when IMAP folder events happen
  # This is how we detect "user moved message to Junk" → train rspamd
  imapsieve_mailbox1_name   = Junk
  imapsieve_mailbox1_causes = COPY FLAG
  imapsieve_mailbox1_before = file:/etc/dovecot/sieve/global/learn-spam.sieve

  imapsieve_mailbox2_name   = INBOX
  imapsieve_mailbox2_from   = Junk
  imapsieve_mailbox2_causes = COPY
  imapsieve_mailbox2_before = file:/etc/dovecot/sieve/global/learn-ham.sieve

  # Allow sieve to run external programs (rspamc)
  sieve_pipe_bin_dir  = /usr/bin
  sieve_global_extensions = +vnd.dovecot.pipe +vnd.dovecot.environment
}
EOF

# ManageSieve service (port 4190)
cat > /etc/dovecot/conf.d/20-managesieve.conf <<EOF
service managesieve-login {
  inet_listener sieve {
    port = 4190
  }
}
service managesieve {
  process_limit = 1024
}
protocol sieve {
  managesieve_logout_format = bytes ( in=%i : out=%o )
}
EOF

# ─────────────────────────────────────────────
# [9/11] Spam reporting via imapsieve
# ─────────────────────────────────────────────
# When a user drags a message to Junk:
#   imapsieve fires learn-spam.sieve
#   which calls rspamc learn_spam on that message
#   rspamd updates its Bayes token counts in Redis
#
# When a user drags a message OUT of Junk to Inbox:
#   imapsieve fires learn-ham.sieve
#   which calls rspamc learn_ham
#   rspamd updates token counts accordingly
#
# Over time, rspamd gets smarter about what YOUR users consider spam.
echo "[9/11] Creating spam reporting sieve scripts..."

cat > /etc/dovecot/sieve/global/learn-spam.sieve <<'EOF'
require ["vnd.dovecot.pipe", "copy", "imapsieve", "environment", "variables"];

if environment :matches "imap.email" "*" {
  set "email" "${1}";
}

pipe :copy "rspamc" ["learn_spam"];
EOF

cat > /etc/dovecot/sieve/global/learn-ham.sieve <<'EOF'
require ["vnd.dovecot.pipe", "copy", "imapsieve", "environment", "variables"];

if environment :matches "imap.email" "*" {
  set "email" "${1}";
}

pipe :copy "rspamc" ["learn_ham"];
EOF

# Compile the sieve scripts
sievec /etc/dovecot/sieve/global/learn-spam.sieve 2>/dev/null || true
sievec /etc/dovecot/sieve/global/learn-ham.sieve  2>/dev/null || true

chown -R vmail:vmail /etc/dovecot/sieve/global/
chmod 644 /etc/dovecot/sieve/global/*.sieve

# ─────────────────────────────────────────────
# [10/11] Auth + LMTP sockets
# ─────────────────────────────────────────────
echo "[10/11] Configuring auth and LMTP sockets..."
cat > /etc/dovecot/conf.d/99-auth-sockets.conf <<EOF
service auth {
  # Postfix uses this socket for SASL authentication
  unix_listener /var/spool/postfix/private/auth {
    mode = 0666
    user = postfix
    group = postfix
  }
  # Dovecot-internal auth socket
  unix_listener auth-userdb {
    mode = 0600
    user = vmail
  }
}

service auth-worker {
  user = vmail
}
EOF

cat > /etc/dovecot/conf.d/99-lmtp.conf <<EOF
service lmtp {
  # Postfix delivers mail to Dovecot via this socket
  unix_listener /var/spool/postfix/private/dovecot-lmtp {
    mode = 0600
    user = postfix
    group = postfix
  }
}

protocol lmtp {
  # Sieve runs on delivery — sorts mail into folders
  mail_plugins = \$mail_plugins sieve
}
EOF

# ─────────────────────────────────────────────
# [11/11] Mailboxes, logging, restart
# ─────────────────────────────────────────────
echo "[11/11] Final config, logging, restart..."
cat > /etc/dovecot/conf.d/15-mailboxes.conf <<EOF
namespace inbox {
  inbox = yes
  mailbox Drafts        { special_use = \Drafts;  auto = subscribe; }
  mailbox Junk          { special_use = \Junk;    auto = subscribe; }
  mailbox Trash         { special_use = \Trash;   auto = subscribe; }
  mailbox Sent          { special_use = \Sent;    auto = subscribe; }
  mailbox "Sent Messages" { special_use = \Sent; }
}
EOF

# Production logging — NO debug_passwords
cat > /etc/dovecot/conf.d/99-logging.conf <<EOF
log_path       = /var/log/dovecot.log
info_log_path  = /var/log/dovecot-info.log
auth_verbose   = yes
# auth_debug   = no   (enable temporarily to diagnose auth failures)
# auth_debug_passwords = no   (NEVER enable in production)
mail_debug     = no
EOF

doveconf -n > /dev/null
systemctl restart dovecot
systemctl enable dovecot

echo
echo "========================================"
echo " Dovecot Configuration Complete"
echo "========================================"
echo
echo " LDAP auth          : passdb + userdb"
echo " Master user        : mailadmin (password in mailserver.conf)"
echo " Maildir storage    : /var/mail/vhosts/\$DOMAIN/\$USER/Maildir"
echo " Quota              : from LDAP mailQuota attribute (default 1G)"
echo " Sieve filters      : ~/sieve  (ManageSieve port 4190)"
echo " Spam reporting     : Junk→rspamd learn_spam, Inbox←rspamd learn_ham"
echo " LMTP socket        : /var/spool/postfix/private/dovecot-lmtp"
echo " TLS                : /etc/ssl/mail/mail.crt"
