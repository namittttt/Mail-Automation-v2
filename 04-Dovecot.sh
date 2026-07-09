#!/bin/bash
set -e
source /opt/mailserver/mailserver.conf

echo " Dovecot Configuration

VMAIL_UID=5000
VMAIL_GID=5000

# ─────────────────────────────────────────────
# [1/11] Mail storage directory
# ─────────────────────────────────────────────
echo "[1/11] Creating mail storage..."
mkdir -p /var/mail/vhosts/$DOMAIN
chown -R vmail:vmail /var/mail/vhosts
chmod 750 /var/mail/vhosts

# /var/mail itself (the parent, standard system mail spool, owned by
# root:mail 0700 by default) blocks traversal for every uid except
# root/mail-group — including vmail. Without +x here, NOTHING can
# reach /var/mail/vhosts at all, no matter how it's chmod'd.
chmod 711 /var/mail

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
# NOTE: %{user} = full login (venkatesh@namit.com), but LDAP stores just
# "uid=venkatesh" (local part only) — this mismatch is why auth was failing
# ("ldap: unknown user" in the debug log, filter never matched anything).
# %{user | username} strips the @domain part to match your directory.
passdb ldap {
  ldap_filter = (&(objectClass=posixAccount)(uid=%{user | username}))
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
  filter = (&(objectClass=posixAccount)(uid=%{user | username}))
  fields {
    home = %{ldap:homeDirectory}
    # Every virtual mail user runs as the SAME shared system account
    # (vmail), not their individual LDAP uidNumber/gidNumber. Mixing
    # per-user Linux identities with vmail-owned storage causes
    # permission errors on every new folder/index file Dovecot creates
    # (dotlock/index files need write access that group r-x won't give
    # an arbitrary per-user uid). Static uid/gid = vmail avoids this
    # entire class of bug.
    uid = vmail
    gid = vmail
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
# protocol imap {
#   mail_plugins {
#     quota = yes
#   }
# }
# protocol lmtp {
#   mail_plugins {
#     quota = yes
#   }
# }
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
# [8/11] Sieve — global plugin config (BUG 3 FIX, v2.4 syntax)
# ─────────────────────────────────────────────
# NOTE: Dovecot 2.4 removed the "plugin { }" block entirely — this is why
# you got: doveconf: Fatal: ... line 1: Unknown section name: plugin
# The old flat imapsieve_mailboxN_* settings are also gone. In 2.4 syntax,
# script storages are named "sieve_script" blocks, and admin (imapsieve)
# scripts are nested inside "mailbox" / "imapsieve_from" filter blocks.
# Reference: https://doc.dovecot.org/2.4.1/core/plugins/sieve.html
#            https://doc.dovecot.org/2.4.1/core/plugins/imap_sieve.html
echo "[8/11] Configuring Sieve..."
cat > /etc/dovecot/conf.d/90-sieve.conf <<'EOF'
# Personal (per-user) Sieve script storage
sieve_script personal {
  driver      = file
  path        = ~/sieve
  active_path = ~/.dovecot.sieve
}

# IMAPSieve admin script: message copied/flagged INTO Junk -> train as spam
mailbox Junk {
  sieve_script learn_spam {
    type = before
    cause = "copy flag"
    path = /etc/dovecot/sieve/global/learn-spam.sieve
  }
}

# IMAPSieve admin script: message copied FROM Junk INTO INBOX -> train as ham
mailbox INBOX {
  imapsieve_from Junk {
    sieve_script learn_ham {
      type = before
      cause = copy
      path = /etc/dovecot/sieve/global/learn-ham.sieve
    }
  }
}

# Enable the IMAP-side plugin so the above mailbox/imapsieve_from hooks fire
protocol imap {
  mail_plugins {
    imap_sieve = yes
  }
}

# Sieve interpreter plugins (registers the imapsieve + extprograms extensions)
sieve_plugins {
  sieve_imapsieve   = yes
  sieve_extprograms = yes
}

# vnd.dovecot.pipe / vnd.dovecot.environment are used by learn-spam.sieve and
# learn-ham.sieve (the "pipe :copy rspamc" calls) — restricted to global
# (admin) scripts only, not exposed to users' personal scripts
sieve_global_extensions {
  vnd.dovecot.pipe        = yes
  vnd.dovecot.environment = yes
}

# Directory containing binaries usable by the sieve "pipe" command (rspamc)
sieve_pipe_bin_dir = /usr/bin
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
# [8.5/11] Sieve directories
# ─────────────────────────────────────────────
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
  mail_plugins {
    sieve = yes
  }
}
EOF

# [11/11] Mailboxes, logging, restart
echo "[11/11] Final config, logging, restart..."

cat > /etc/dovecot/conf.d/15-mailboxes.conf <<'EOF'
namespace inbox {
  inbox = yes

  mailbox Drafts {
    special_use = \Drafts
    auto = create
  }

  mailbox Junk {
    special_use = \Junk
    auto = create
  }

  mailbox Trash {
    special_use = \Trash
    auto = create
  }

  mailbox Sent {
    special_use = \Sent
    auto = create
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
