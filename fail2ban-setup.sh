#!/usr/bin/env bash
# Installs and configures fail2ban's SSH jail (brute force). Read before
# running, fill in SSH_PORT.
#
# No nginx jail here: in this setup (selfsteal — Reality sits directly on
# 443) nginx only ever serves port 80 for ACME and writes no per-connection
# log fail2ban could watch for scanner-like behavior on 443 — see
# nginx.conf.
set -euo pipefail

SSH_PORT=REPLACE_WITH_YOUR_SSH_PORT

apt install -y fail2ban

# The jail ships with fail2ban itself (jail.conf); this only overrides the
# port and explicitly enables it in jail.local (don't touch jail.conf —
# it gets overwritten on package upgrades).
cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
port = ${SSH_PORT}
maxretry = 5
findtime = 10m
bantime = 1h
EOF

systemctl enable --now fail2ban
systemctl restart fail2ban

echo "Check: fail2ban-client status; fail2ban-client status sshd"
