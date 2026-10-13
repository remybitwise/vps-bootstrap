#!/usr/bin/env bash
# Installs and configures fail2ban: an SSH jail (brute force) + optionally
# a jail on nginx's stream log (frequent connections from one IP —
# scanners/probes; only where nginx actually still terminates 443 via the
# stream module, see NGINX_HAS_STREAM_LOG below). Read before running, fill
# in SSH_PORT.
set -euo pipefail

SSH_PORT=REPLACE_WITH_YOUR_SSH_PORT

# In this setup (selfsteal — Reality sits directly on 443), nginx no longer
# terminates 443 and writes no stream-access.log at all — there's nowhere
# and no reason to put a jail on it. If your setup is different and nginx
# still acts as an SNI router on 443 (writing stream-access.log), set
# NGINX_HAS_STREAM_LOG=1.
NGINX_HAS_STREAM_LOG=0

apt install -y fail2ban

# -----------------------------------------------------------------------
# SSH — the jail ships with fail2ban itself (jail.conf); this only
# overrides the port and explicitly enables it in jail.local (don't touch
# jail.conf — it gets overwritten on package upgrades).
# -----------------------------------------------------------------------
cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
port = ${SSH_PORT}
maxretry = 5
findtime = 10m
bantime = 1h
EOF

if [ "$NGINX_HAS_STREAM_LOG" = "1" ]; then
# -----------------------------------------------------------------------
# nginx stream — a custom filter; fail2ban ships no standard nginx jails
# for the stream module (those are built for http access logs with
# response codes). Logic: many TCP connections to 443 from one IP in a
# short time — regardless of correct SNI or not — doesn't look like one
# legitimate client (a urltest check every 3 minutes plus normal traffic
# doesn't produce that rate), it looks like a scanner/active probe.
# -----------------------------------------------------------------------
cat > /etc/fail2ban/filter.d/nginx-stream-probe.conf <<'EOF'
[Definition]
# line format — see log_format basic in nginx.conf:
# $remote_addr [$time_local] $protocol $status $bytes_sent $bytes_received $ssl_preread_server_name
failregex = ^<HOST> \[.*\] \S+ \S+ \S+ \S+
ignoreregex =
EOF

cat > /etc/fail2ban/jail.d/nginx-stream-probe.local <<'EOF'
[nginx-stream-probe]
enabled = true
filter = nginx-stream-probe
logpath = /var/log/nginx/stream-access.log
maxretry = 20
findtime = 60
bantime = 1h
action = %(action_)s
EOF
fi

systemctl enable --now fail2ban
systemctl restart fail2ban

echo "Check: fail2ban-client status; fail2ban-client status sshd"
if [ "$NGINX_HAS_STREAM_LOG" = "1" ]; then
echo "  fail2ban-client status nginx-stream-probe"
echo "NOTE: maxretry/findtime for nginx-stream-probe (20 connections/60 sec) is a starting"
echo "point, tune it to your real load (several devices with urltest every 3 min shouldn't trip the ban;"
echo "if you see false positives, raise maxretry or findtime)."
fi
