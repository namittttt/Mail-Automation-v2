
#!/bin/bash

echo "[1/4] Installing Sieve packages..."
sudo apt install -y dovecot-sieve dovecot-managesieved roundcube-plugins

echo "[2/4] Uncommenting sieve in dovecot config files..."

# Uncomment mail_plugins { and sieve = yes in 20-imap.conf
sudo sed -i 's/^[[:space:]]*#[[:space:]]*mail_plugins {/mail_plugins {/' /etc/dovecot/conf.d/20-imap.conf
sudo sed -i 's/^[[:space:]]*#[[:space:]]*sieve = yes/sieve = yes/' /etc/dovecot/conf.d/20-imap.conf

# Uncomment mail_plugins in 20-lmtp.conf
sudo sed -i 's/^[[:space:]]*#[[:space:]]*mail_plugins = \$mail_plugins sieve/mail_plugins = $mail_plugins sieve/' /etc/dovecot/conf.d/20-lmtp.conf
sudo sed -i 's/^[[:space:]]*#[[:space:]]*mail_plugins {/mail_plugins {/' /etc/dovecot/conf.d/20-lmtp.conf
sudo sed -i 's/^[[:space:]]*#[[:space:]]*sieve = yes/sieve = yes/' /etc/dovecot/conf.d/20-lmtp.conf

# Uncomment mail_plugins { and sieve = yes in 15-lda.conf
sudo sed -i 's/^[[:space:]]*#[[:space:]]*mail_plugins {/mail_plugins {/' /etc/dovecot/conf.d/15-lda.conf
sudo sed -i 's/^[[:space:]]*#[[:space:]]*sieve = yes/sieve = yes/' /etc/dovecot/conf.d/15-lda.conf

echo "[3/4] Enabling roundcube managesieve plugin..."
sudo sed -i "s/^[[:space:]]*#[[:space:]]*'managesieve'/'managesieve'/" /var/lib/roundcube/config/config.inc.php
sudo sed -i "s/^[[:space:]]*#[[:space:]]*\$config\['managesieve_host'\]/\$config['managesieve_host']/" /var/lib/roundcube/plugins/managesieve/config.inc.php

echo "[4/4] Restarting services..."
sudo systemctl restart dovecot
sudo systemctl restart apache2

echo "✓ Complete! Check Settings → Filters in Roundcube"
