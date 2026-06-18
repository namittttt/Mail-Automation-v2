#!/bin/bash

set -e

source /opt/mailserver/mailserver.conf

echo "========================================"
echo " Dovecot Configuration"
echo "========================================"

echo "[1/7] Creating Mail Storage..."

mkdir -p /var/mail/vhosts/$DOMAIN

groupadd -f vmail

if ! id vmail >/dev/null 2>&1; then
    useradd -r -g vmail -d /var/mail/vhosts \
    -s /usr/sbin/nologin vmail
fi

chown -R vmail:vmail /var/mail/vhosts

echo "[2/7] Configuring LDAP Authentication..."

cat > /etc/dovecot/conf.d/auth-ldap.conf.ext <<EOF
ldap_uris = ldap://localhost

ldap_auth_dn = $ADMINDN
ldap_auth_dn_password = $LDAPPASS

ldap_base = $BASEDN

passdb ldap {

  ldap_filter = (&(objectClass=posixAccount)(uid=%{user}))

  ldap_bind = no

  fields {
    user=%{ldap:uid}
    password=%{ldap:userPassword}
    userdb_home=%{ldap:homeDirectory}
    userdb_uid=%{ldap:uidNumber}
    userdb_gid=%{ldap:gidNumber}
  }
}

userdb ldap {

  fields {
    home=%{ldap:homeDirectory}
    uid=%{ldap:uidNumber}
    gid=%{ldap:gidNumber}
  }

  filter = (&(objectClass=posixAccount)(uid=%{user}))
}
EOF

echo "[3/7] Enabling LDAP Auth..."

cat > /etc/dovecot/conf.d/10-auth.conf <<EOF
auth_allow_cleartext = yes

disable_plaintext_auth = no

auth_mechanisms = plain login

!include auth-ldap.conf.ext
EOF

echo "[4/7] Configuring Mail Storage..."

cat > /etc/dovecot/conf.d/10-mail.conf <<EOF
mail_driver = maildir

mail_path = ~/Maildir

mail_privileged_group = mail
EOF

echo "[5/7] Configuring Auth Service..."

cat > /etc/dovecot/conf.d/99-auth.conf <<EOF
service auth {

  unix_listener auth-client {
    mode = 0666
  }

  unix_listener auth-userdb {
    mode = 0666
  }

  unix_listener /var/spool/postfix/private/auth {
    mode = 0666
    user = postfix
    group = postfix
  }
}
EOF

echo "[6/7] Configuring LMTP..."

cat > /etc/dovecot/conf.d/99-lmtp.conf <<EOF
service lmtp {

  unix_listener /var/spool/postfix/private/dovecot-lmtp {
    mode = 0600
    user = postfix
    group = postfix
  }
}
EOF

echo "[7/7] Restarting Dovecot..."

doveconf -n >/dev/null

systemctl restart dovecot

systemctl enable dovecot

echo
echo "========================================"
echo " Dovecot Configuration Complete"
echo "========================================"
