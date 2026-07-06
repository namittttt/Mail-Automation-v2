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
# [1.5] Inject mandatory config versions into dovecot.conf
# ─────────────────────────────────────────────
echo "[1.5] Setting mandatory configuration versioning..."
# Dovecot 2.4+ requires versioning tokens at the absolute top of the primary config file
if ! grep -q "dovecot_config_version" /etc/dovecot/dovecot.conf 2>/dev/null; then
    sed -i '1i dovecot_config_version = 2.4.0\ndovecot_storage_version = 2.4.0' /etc/dovecot/dovecot.conf
fi

# ─────────────────────────────────────────────
# [2/11] TLS — Server Certificates
# ─────────────────────────────────────────────
echo "[2/11] Configuring TLS..."
cat > /etc/dovecot/conf.d/10-ssl.conf <<EOF
ssl = required
ssl_server_cert_file = /etc/ssl/mail/mail.crt
ssl_server_key_file = /etc/ssl/mail/mail.key
# Cleartext authentication over non-TLS connections is disabled globally via auth_allow_cleartext
EOF

# ─────────────────────────────────────────────
# [3/11] LDAP authentication (passdb + userdb)
# ─────────────────────────────────────────────
echo "[3/11] Configuring LDAP auth..."
cat > /etc/dovecot/conf.d/auth-ldap.conf.ext <<EOF
ldap_uris            = ldap://localhost
ldap_auth_dn         = $ADMINDN
ldap_auth_dn_password = $LDAPPASS
ldap_base            = $BASEDN

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
  }
}

# userdb: get mailbox location and uid/gid for mail delivery
userdb ldap {
  filter = (&(objectClass=posixAccount)(uid=%{user}))
  fields {
    home        = %{ldap:homeDirectory}
    uid         = %{ldap:uidNumber}
    gid         = %{ldap:gidNumber}
  }
}
EOF

# ─────────────────────────────────────────────
# [5/11] Auth mechanisms + auth config
# ─────────────────────────────────────────────
echo "[5/11] Configuring auth mechanisms..."
cat > /etc/dovecot/conf.d/10-auth.conf <<EOF
auth_allow_cleartext = no
auth_mechanisms = plain login
!include auth-ldap.conf.ext
EOF

# ─────────────────────────────────────────────
# [6/11] Mail storage (Maildir layout)
# ─────────────────────────────────────────────
# BUG 1 FIX: "quota" removed from mail_plugins because the quota plugin
# config block (step 7) is disabled. Loading the plugin with no matching
# config block is what threw: fatal: plugin '$mail_plugins' not found
echo "[6/11] Configuring mail storage..."
cat > /etc/dovecot/conf.d/10-mail.conf <<EOF
mail_driver           = maildir
mail_path             = ~/Maildir
mail_privileged_group = mail
EOF

# ─────────────────────────────────────────────
# [7/11] Quota — disabled
# ─────────────────────────────────────────────
# Left intentionally disabled. If you want quotas back later, re-enable this
# whole block AND re-add "quota" to mail_plugins in step 6 above — they must
# always be turned on/off together.
#
# echo "[7/11] Configuring quota..."
# cat >> /etc/dovecot/conf.d/10-mail.conf <<'EOF'
# mail_plugins = $mail_plugins quota
#
# quota "User quota" {
#   driver = count
# }
#
# quota_warning "90percent" {
#   bytes = 90%
#   command = "quota-warning 90 %u"
# }
#
# quota_warning "100percent" {
#   bytes = 100%
#   command = "quota-warning 100 %u"
# }
#
# service quota-status {
#   executable = quota-status -p postfix
#   inet_listener {
#     port = 12340
#   }
# }
#
# service quota-warning {
#   executable = script /usr/local/bin/quota-warning.sh
#   user = vmail
#   unix_listener quota-warning {
#     user = vmail
#     mode = 0600
#   }
# }
# EOF
#
# cat > /usr/local/bin/quota-warning.sh <<'SCRIPT'
# #!/bin/bash
# source /opt/mailserver/mailserver.conf
# PERCENT=$1
# USER=$2
# printf "From: postmaster@${DOMAIN}\nTo: ${USER}\nSubject: Mailbox quota warning: ${PERCENT}%% used\n\nYour mailbox is ${PERCENT}%% full.\nPlease delete old messages or contact your administrator.\n" \
#     | sendmail -f "postmaster@${DOMAIN}" "${USER}"
# SCRIPT
# chmod +x /usr/local/bin/quota-warning.sh
#
# postconf -e "smtpd_end_of_data_restrictions = check_policy_service inet:localhost:12340"

# ─────────────────────────────────────────────
# [8/11] Sieve — global plugin config (BUG 3 FIX)
# ─────────────────────────────────────────────
# This file was missing entirely. 99-lmtp.conf loads the sieve plugin, so
# without this config block Dovecot has nothing to configure it with —
# same class of error as Bug 1.
echo "[8/11] Configuring Sieve..."
cat > /etc/dovecot/conf.d/90-sieve.conf <<'EOF'
plugin {
  sieve = file:~/sieve;active=~/.dovecot.sieve
  sieve_global = /etc/dovecot/sieve/global/
  sieve_plugins = sieve_imapsieve sieve_extprograms

  imapsieve_mailbox1_name   = Junk
  imapsieve_mailbox1_causes = COPY FLAG
  imapsieve_mailbox1_before = file:/etc/dovecot/sieve/global/learn-spam.sieve

  imapsieve_mailbox2_name   = INBOX
  imapsieve_mailbox2_from   = Junk
  imapsieve_mailbox2_causes = COPY
  imapsieve_mailbox2_before = file:/etc/dovecot/sieve/global/learn-ham.sieve

  sieve_pipe_bin_dir = /usr/bin
  sieve_global_extensions = +vnd.dovecot.pipe +vnd.dovecot.environment
}
EOF

cat > /etc/dovecot/conf.d/20-managesieve.conf <<'EOF'
service managesieve-login {
  inet_listener sieve {
    port = 4190
  }
}
service managesieve {
  process_limit = 1024
}
EOF

# ─────────────────────────────────────────────
# [8.5/11] Sieve directories (BUG 2 FIX)
# ─────────────────────────────────────────────
# mkdir was missing, so writing learn-spam.sieve / learn-ham.sieve below
# would have failed (No such file or directory).
echo "[8.5/11] Creating sieve directories..."
mkdir -p /etc/dovecot/sieve/global
chown root:vmail /etc/dovecot/sieve/global
chmod 750 /etc/dovecot/sieve/global

# ─────────────────────────────────────────────
# [9/11] Spam reporting via imapsieve
# ─────────────────────────────────────────────
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
  unix_listener /var/spool/postfix/private/auth {
    mode = 0666
    user = postfix
    group = postfix
  }
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
  unix_listener /var/spool/postfix/private/dovecot-lmtp {
    mode = 0600
    user = postfix
    group = postfix
  }
}

protocol lmtp {
  mail_plugins = \$mail_plugins sieve
}
EOF

# ─────────────────────────────────────────────
# [11/11] Mailboxes, logging, restart
# ─────────────────────────────────────────────
echo "[11/11] Final config, logging, restart..."

cat > /etc/dovecot/conf.d/15-mailboxes.conf <<'EOF'
namespace inbox {
  inbox = yes

  mailbox Drafts {
    special_use = \Drafts
    auto = subscribe
  }

  mailbox Junk {
    special_use = \Junk
    auto = subscribe
  }

  mailbox Trash {
    special_use = \Trash
    auto = subscribe
  }

  mailbox Sent {
    special_use = \Sent
    auto = subscribe
  }

  mailbox "Sent Messages" {
    special_use = \Sent
  }
}
EOF

# Production logging format updates
cat > /etc/dovecot/conf.d/99-logging.conf <<EOF
log_path       = /var/log/dovecot.log
info_log_path  = /var/log/dovecot-info.log
log_debug      = category=auth
mail_debug     = no
EOF

# Run validation syntax utility
doveconf -n > /dev/null
systemctl restart dovecot
systemctl enable dovecot

echo
echo "========================================"
echo " Dovecot Configuration Complete"
echo "========================================"
