#!/usr/bin/env bash
# Read before running. Fill in your real SSH port as SSH_PORT.
# Be CAREFUL running this over SSH: get the port wrong and you lose access.
# Recommended: open the new SSH port first and confirm it works, only then
# run this to deny everything else.
set -euo pipefail

SSH_PORT=REPLACE_WITH_YOUR_SSH_PORT   # NOT 22 — change the port in sshd_config beforehand

# purge+rm instead of a plain install — some images already ship an old/
# nonstandard /etc/default/ufw (e.g. with malformed quoting on
# DEFAULT_INPUT_POLICY), which later makes ufw fail with "ERROR: Missing
# policy for 'input'". This guarantees a clean file from the package, and
# also skips the config-file-conflict prompt.
apt purge -y ufw 2>/dev/null || true
rm -f /etc/default/ufw
DEBIAN_FRONTEND=noninteractive apt install -y ufw

# sanity check: if the policies still didn't parse even after a clean
# install, better to stop now with a clear error than hit "Missing policy
# for 'input'" on the next command.
grep -qE '^DEFAULT_INPUT_POLICY="' /etc/default/ufw || { echo "ERROR: /etc/default/ufw still looks broken, investigate by hand (grep DEFAULT_INPUT_POLICY /etc/default/ufw)"; exit 1; }

# IPv6 is deliberately unused in this setup (nginx/services only listen on
# IPv4) — disable IPv6 management in ufw itself; full kernel-level
# disabling is done by harden-server.sh (run that too, order relative to
# this script doesn't matter). Smaller surface, less chance of anything
# ending up reachable over IPv6 with no firewall rule covering it.
sed -i 's/^IPV6=.*/IPV6=no/' /etc/default/ufw

ufw default deny incoming
ufw default allow outgoing

ufw limit "${SSH_PORT}/tcp"    # limit, not allow — throttles brute-force attempts
ufw allow 80/tcp
ufw allow 443/tcp

ufw --force enable
ufw status verbose
