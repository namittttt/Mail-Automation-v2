#!/bin/bash

echo "[1/5] Installing Sieve packages..."
sudo apt install -y dovecot-sieve dovecot-managesieved roundcube-plugins

echo "[2/5] Configuring 20-imap.conf..."
sudo cat > /etc/dovecot/conf.d/20-imap.conf <<'EOF'
protocol imap {
  mail_plugins {
    sieve = yes
  }
}
EOF

echo "[3/5] Configuring 20-lmtp.conf..."
sudo cat > /etc/dovecot/conf.d/20-lmtp.conf <<'EOF'
protocol lmtp {
  mail_plugins = $mail_plugins sieve
}
protocol lmtp {
  mail_plugins {
    sieve = yes
  }
  auth_username_format = %{user | lower}
}
EOF

echo "[4/5] Configuring 15-lda.conf..."
sudo cat > /etc/dovecot/conf.d/15-lda.conf <<'EOF'
protocol lda {
  mail_plugins {
    sieve = yes
  }
}
EOF

echo "[5/5] Configuring Roundcube managesieve..."
sudo cat > /var/lib/roundcube/config/config.inc.php <<'EOF'
$config['plugins'] = [
     'managesieve',
];
EOF

sudo cat > /var/lib/roundcube/plugins/managesieve/config.inc.php <<'EOF'
$config['managesieve_host'] = 'localhost';
EOF

echo "[6/6] Restarting services..."
sudo systemctl restart dovecot
sudo systemctl restart apache2

echo "✓ Complete!"
sudo doveconf -n | grep -A 5 "mail_plugins"
