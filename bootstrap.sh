#!/usr/bin/env bash
# bootstrap.sh — stands up the whole stack on a clean VPS: sing-box
# (VLESS+Reality + naive), Caddy (naive camouflage + decoy), qWDTT
# (whitelist bypass via TPROXY), Psiphon (second egress for Google) +
# watchdog, firewall, base kernel hardening, fail2ban. Details — README.md
# next to this file.
#
# SSH key setup and hardening (port change, password login off) are
# deliberately not here — see SSH-HARDENING.md. That step is easy to do by
# hand with a check in a separate session, and easy to break beyond
# recovery with automation and no human watching. Run this script only
# once SSH by key on the right port already works.
#
# The script can be re-run — it brings every binary and config up to date,
# but doesn't touch what can't be regenerated: client secrets, the current
# Psiphon region (the watchdog's rotation moves it), and the
# MIN_THROUGHPUT_KBPS calibration if it's no longer the default.
#
# Not run end to end a second time on an already-configured server —
# testing that on the production box this script exists to recover is not
# a risk worth taking. Each block on its own is a command already run
# live; stringing them together in this exact order hasn't been. Watch the
# output at every step on a first run against a new machine.

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# =========================================================================
# CONFIG — fill in before running (or export as env vars)
# =========================================================================

DOMAIN="${DOMAIN:?set DOMAIN=your.domain (its A record must already point at this VPS)}"
EMAIL="${EMAIL:?set EMAIL=your@email (used only for issuing the certificate)}"
SSH_PORT="${SSH_PORT:?set SSH_PORT=number (the one already configured in sshd_config)}"
PSIPHON_EGRESS_REGION="${PSIPHON_EGRESS_REGION:?set PSIPHON_EGRESS_REGION=NL (two-letter code; Psiphon itself prints the full list to its log on first run, AvailableEgressRegions)}"

# Client names — each gets its own Reality UUID and naive login/password.
# The default below is just a single-client placeholder; pass your own via
# CLIENT_NAMES="name1 name2 name3" (space separated, any names).
# export is required: the python helpers below read this from os.environ,
# which only sees what's actually exported, not any bash variable.
export CLIENT_NAMES="${CLIENT_NAMES:-client1}"

WDTT_DTLS_PORT="${WDTT_DTLS_PORT:-48219}"
WDTT_WG_PORT="${WDTT_WG_PORT:-48220}"
WDTT_TPROXY_PORT="${WDTT_TPROXY_PORT:-12345}"

# All templates live next to this script, in the same folder.
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_FILE="/root/.vps-bootstrap-secrets.env"

[ "$(id -u)" = "0" ] || { echo "ERROR: run as root"; exit 1; }

log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }

log "0/12 — apt-get update"
apt-get update -qq

# =========================================================================
# 0. sing-box binary (always to the latest version — safe: apt .deb, then
#    an explicit restart below) + secrets (generate once, read after —
#    a re-run never touches them, whatever binaries/configs changed above)
# =========================================================================

log "updating sing-box to the latest version"
bash <(curl -fsSL https://sing-box.app/install.sh) >/dev/null

if [ -f "$SECRETS_FILE" ]; then
  log "Secrets already generated ($SECRETS_FILE) — reusing"
  # shellcheck disable=SC1090
  . "$SECRETS_FILE"
else
  log "First run — generating secrets"
  REALITY_KEYS="$(sing-box generate reality-keypair)"
  REALITY_PRIVATE_KEY="$(echo "$REALITY_KEYS" | grep PrivateKey | awk '{print $2}')"
  REALITY_PUBLIC_KEY="$(echo "$REALITY_KEYS" | grep PublicKey | awk '{print $2}')"
  SHORT_ID="$(sing-box generate rand --hex 8)"

  {
    echo "REALITY_PRIVATE_KEY=$REALITY_PRIVATE_KEY"
    echo "REALITY_PUBLIC_KEY=$REALITY_PUBLIC_KEY"
    echo "SHORT_ID=$SHORT_ID"
  } > "$SECRETS_FILE"

  for name in $CLIENT_NAMES; do
    uuid="$(sing-box generate uuid)"
    pass="$(openssl rand -base64 24)"
    echo "CLIENT_${name}_UUID=$uuid" >> "$SECRETS_FILE"
    echo "CLIENT_${name}_NAIVE_PASS=$pass" >> "$SECRETS_FILE"
  done

  chmod 600 "$SECRETS_FILE"
  # shellcheck disable=SC1090
  . "$SECRETS_FILE"
fi

# =========================================================================
# 1. Firewall
# =========================================================================

log "1/12 — ufw"
tmp_ufw="$(mktemp)"
sed "s/REPLACE_WITH_YOUR_SSH_PORT/${SSH_PORT}/" "$REPO_DIR/ufw-setup.sh" > "$tmp_ufw"
bash "$tmp_ufw"
rm -f "$tmp_ufw"

# =========================================================================
# 2. Base hardening (BBR, sysctl, unattended upgrades)
# =========================================================================

log "2/12 — harden-server.sh"
bash "$REPO_DIR/harden-server.sh"

# =========================================================================
# 3. nginx — port 80 only, for ACME
# =========================================================================

log "3/12 — nginx"
apt install -y nginx acl certbot >/dev/null
mkdir -p /var/www/certbot
sed "s/REPLACE_WITH_YOUR_NAIVE_DOMAIN/${DOMAIN}/" "$REPO_DIR/nginx.conf" > /etc/nginx/nginx.conf
nginx -t
systemctl enable --now nginx
systemctl reload nginx

# =========================================================================
# 4. Certificate
# =========================================================================

log "4/12 — certbot"
if [ "${SKIP_CERTBOT:-0}" = "1" ]; then
  # CI/testing only: no real domain pointed at this machine to pass an
  # HTTP-01 challenge, so a self-signed cert stands in at the same path
  # certbot would use. Never set this for a real deployment.
  log "SKIP_CERTBOT=1 — generating a self-signed certificate instead of a real one"
  mkdir -p "/etc/letsencrypt/live/${DOMAIN}" "/etc/letsencrypt/archive/${DOMAIN}"
  openssl req -x509 -nodes -newkey rsa:2048 -days 1 \
    -keyout "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" \
    -out "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" \
    -subj "/CN=${DOMAIN}" -addext "subjectAltName=DNS:${DOMAIN}" >/dev/null 2>&1
elif [ ! -d "/etc/letsencrypt/live/${DOMAIN}" ]; then
  certbot certonly --webroot -w /var/www/certbot -d "$DOMAIN" --agree-tos -m "$EMAIL" --non-interactive
else
  log "certificate for ${DOMAIN} already exists, skipping issuance"
fi

# =========================================================================
# 5. Caddy for naive
# =========================================================================

log "5/12 — Caddy"
id caddy >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin caddy
mkdir -p /etc/caddy /var/log/caddy /var/lib/caddy /var/www/html
chown caddy:caddy /var/lib/caddy

# Always to the latest version, not just on first install. Stop before
# swapping the binary rather than over a running process — restart after,
# below, together with regenerating the Caddyfile. Several commands run
# between the stop and the restart (Caddyfile regen, cert ACL/readability
# checks, caddy validate); under set -e any one of them failing would
# otherwise kill the script with caddy-naive left stopped and nothing to
# bring it back — the trap below catches exactly that and is cleared once
# the real restart below succeeds.
CADDY_URL=$(curl -s https://api.github.com/repos/caddyserver/caddy/releases/latest \
  | grep browser_download_url | grep "linux_amd64.tar.gz\"" | cut -d '"' -f4)
curl -fsSL -o /tmp/caddy.tar.gz "$CADDY_URL"
mkdir -p /tmp/caddy-extract
tar xzf /tmp/caddy.tar.gz -C /tmp/caddy-extract
systemctl stop caddy-naive 2>/dev/null || true
trap 'systemctl start caddy-naive 2>/dev/null || true' EXIT
mv /tmp/caddy-extract/caddy /usr/local/bin/caddy
chmod +x /usr/local/bin/caddy
rm -rf /tmp/caddy.tar.gz /tmp/caddy-extract

sed "s/REPLACE_WITH_YOUR_NAIVE_DOMAIN/${DOMAIN}/g" "$REPO_DIR/decoy-site/index.html" > /var/www/html/index.html

# Caddyfile — one @naive matcher for all clients via header_regexp with OR
# (several separate @naive blocks sharing one matcher name don't work —
# "matcher is defined more than once"). Generator lives in
# regen-caddyfile.py; manage.sh keeps its own copy of the same logic (it's
# self-contained, no external files), but it doesn't exist yet on a first
# deployment, hence the separate call here.
python3 "$REPO_DIR/regen-caddyfile.py" "$DOMAIN" "$SECRETS_FILE" /etc/caddy/Caddyfile

chown -R caddy:caddy /etc/caddy
chmod 600 /etc/caddy/Caddyfile

setfacl -R -m u:caddy:rX /etc/letsencrypt/live /etc/letsencrypt/archive
setfacl -R -d -m u:caddy:rX /etc/letsencrypt/live /etc/letsencrypt/archive
sudo -u caddy test -r "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" \
  || { echo "ERROR: caddy can't read the certificate"; exit 1; }

caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile

cp "$REPO_DIR/caddy-naive.service" /etc/systemd/system/caddy-naive.service
systemctl daemon-reload
systemctl enable --now caddy-naive
systemctl restart caddy-naive
trap - EXIT

certbot renew --deploy-hook "systemctl restart caddy-naive" --dry-run >/dev/null 2>&1 || true

# =========================================================================
# 6. sing-box — config (Reality + naive + room for qWDTT/Psiphon below)
# =========================================================================

log "6/12 — sing-box config"
id sing-box >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin sing-box
mkdir -p /etc/sing-box /var/log/sing-box

python3 - "$DOMAIN" "$SECRETS_FILE" "$WDTT_TPROXY_PORT" <<'PYEOF'
import json, os, sys

domain, secrets_file, tproxy_port = sys.argv[1], sys.argv[2], int(sys.argv[3])

env = {}
with open(secrets_file) as f:
    for line in f:
        line = line.strip()
        if not line or "=" not in line:
            continue
        k, v = line.split("=", 1)
        env[k] = v

client_names = os.environ["CLIENT_NAMES"].split()

vless_users = [
    {"name": n, "uuid": env[f"CLIENT_{n}_UUID"], "flow": "xtls-rprx-vision"}
    for n in client_names
]
naive_users = [
    {"username": n, "password": env[f"CLIENT_{n}_NAIVE_PASS"]}
    for n in client_names
]

config = {
    "log": {"level": "warn", "output": "/var/log/sing-box/box.log", "timestamp": True},
    "dns": {
        "servers": [{"type": "https", "tag": "doh", "server": "1.1.1.1", "server_port": 443}],
        "strategy": "ipv4_only",
    },
    "inbounds": [
        {
            "type": "vless",
            "tag": "vless-reality-in",
            "listen": "0.0.0.0",
            "listen_port": 443,
            "tcp_fast_open": True,
            "users": vless_users,
            "tls": {
                "enabled": True,
                "server_name": domain,
                "reality": {
                    "enabled": True,
                    "handshake": {"server": "127.0.0.1", "server_port": 8446},
                    "private_key": env["REALITY_PRIVATE_KEY"],
                    "short_id": [env["SHORT_ID"]],
                },
            },
        },
        {
            "type": "naive",
            "tag": "naive-in",
            "listen": "127.0.0.1",
            "listen_port": 1080,
            "network": "tcp",
            "users": naive_users,
        },
        {
            "type": "tproxy",
            "tag": "wdtt-tproxy-in",
            "listen": "0.0.0.0",
            "listen_port": tproxy_port,
        },
    ],
    "outbounds": [
        {"type": "direct", "tag": "direct"},
        {"type": "socks", "tag": "psiphon-out", "server": "127.0.0.1", "server_port": 11080},
    ],
    "route": {
        "rule_set": [
            {
                "type": "remote", "tag": "google-geosite", "format": "binary",
                "url": "https://raw.githubusercontent.com/KaringX/karing-ruleset/sing/geo/geosite/google.srs",
                "download_detour": "direct", "update_interval": "1d",
            },
            {
                "type": "remote", "tag": "google-geoip", "format": "binary",
                "url": "https://raw.githubusercontent.com/KaringX/karing-ruleset/sing/geo/geoip/google.srs",
                "download_detour": "direct", "update_interval": "1d",
            },
        ],
        "rules": [
            {"inbound": ["vless-reality-in", "naive-in", "wdtt-tproxy-in"], "action": "sniff"},
            {"rule_set": ["google-geosite", "google-geoip"], "action": "route", "outbound": "psiphon-out"},
            {"ip_is_private": True, "action": "reject"},
            {"protocol": "bittorrent", "action": "reject"},
        ],
        "final": "direct",
    },
}

json.dump(config, open("/etc/sing-box/config.json", "w"), indent=2)
print("sing-box config.json written")
PYEOF

chown -R sing-box:sing-box /etc/sing-box /var/log/sing-box
chmod 600 /etc/sing-box/config.json
sing-box check -c /etc/sing-box/config.json

cat > /etc/systemd/system/sing-box.service <<'EOF'
[Unit]
Description=sing-box
After=network.target nss-lookup.target caddy-naive.service
# Wants=, not Requires=: Requires= would stop sing-box every time
# caddy-naive stops (e.g. for a binary upgrade), which it shouldn't.
Wants=caddy-naive.service

[Service]
User=sing-box
Group=sing-box
WorkingDirectory=/etc/sing-box
ExecStart=/usr/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
UMask=0077
NoNewPrivileges=true
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
ProtectSystem=strict
ReadWritePaths=/var/log/sing-box
ProtectHome=true
PrivateTmp=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectClock=true
RestrictNamespaces=true
LockPersonality=true
RestrictSUIDSGID=true
RemoveIPC=true
RestrictAddressFamilies=AF_INET AF_UNIX AF_NETLINK
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now sing-box
systemctl restart sing-box

# =========================================================================
# 7. qWDTT — build from source
# =========================================================================

log "7/12 — qWDTT: build"
if ! command -v /usr/local/go/bin/go >/dev/null 2>&1; then
  curl -fsSL https://go.dev/dl/go1.26.6.linux-amd64.tar.gz -o /tmp/go.tar.gz
  rm -rf /usr/local/go
  tar -C /usr/local -xzf /tmp/go.tar.gz
  rm -f /tmp/go.tar.gz
fi
export PATH=/usr/local/go/bin:$PATH

apt install -y git >/dev/null
mkdir -p /root/build

if [ ! -d /root/build/qwdtt-src ]; then
  git clone --depth 1 https://github.com/SpaceNeuroX/proxy-turn-vk-android.git /root/build/qwdtt-src
else
  git -C /root/build/qwdtt-src fetch --depth 1 origin
  git -C /root/build/qwdtt-src reset --hard FETCH_HEAD
fi

# Stopping before a rebuild is mandatory: the service periodically
# overwrites passwords.json from its own memory, and rebuilding/restarting
# without stopping first risks a race — a just-made edit (vk_hash etc.)
# could be lost. The trap guards the build itself: if it fails (bad
# network fetching modules, incompatible Go version, upstream repo
# gone), set -e would otherwise kill the script with wdtt left stopped
# and the old binary never restarted.
systemctl stop wdtt 2>/dev/null || true
trap 'systemctl start wdtt 2>/dev/null || true' EXIT
(cd /root/build/qwdtt-src && go build -o /usr/local/bin/wdtt-server ./server)
chmod 755 /usr/local/bin/wdtt-server

# =========================================================================
# 8. qWDTT — user, passwords (no bot/API), permissions
# =========================================================================

log "8/12 — qWDTT: deployment"
id wdtt >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin wdtt
mkdir -p /etc/wdtt

if [ ! -f /etc/wdtt/passwords.json ]; then
  python3 - <<PYEOF
import json, os, secrets, string

alphabet = string.ascii_letters + string.digits
def genpass(n=23):
    return "".join(secrets.choice(alphabet) for _ in range(n))

client_names = os.environ["CLIENT_NAMES"].split()
db = {
    "main_password": "",
    "admin_id": "",
    "bot_token": "",
    "passwords": {},
    "devices": {},
}
for name in client_names:
    db["passwords"][genpass()] = {
        "label": name,
        "device_id": "",
        "device_ids": [],
        "max_devices": 1,
        "expires_at": 0,
        "down_bytes": 0,
        "up_bytes": 0,
    }

json.dump(db, open("/etc/wdtt/passwords.json", "w"), indent=2)
print("passwords.json written — the VK call hash (vk_hash) is not filled in for anyone.")
print("Create a regular VK group call for each person separately, grab the")
print("hash from it, and enter it by hand into /etc/wdtt/passwords.json, in")
print("that person's vk_hash field under passwords{}.")
PYEOF
else
  log "/etc/wdtt/passwords.json already exists — leaving it alone (not regenerating client passwords)"
fi
chown -R wdtt:wdtt /etc/wdtt
chmod 600 /etc/wdtt/passwords.json

sed \
  -e "s/REPLACE_WITH_WDTT_DTLS_PORT/${WDTT_DTLS_PORT}/g" \
  -e "s/REPLACE_WITH_WDTT_WG_PORT/${WDTT_WG_PORT}/g" \
  -e "s/REPLACE_WITH_WDTT_TPROXY_PORT/${WDTT_TPROXY_PORT}/g" \
  "$REPO_DIR/wdtt.service" > /etc/systemd/system/wdtt.service

systemctl daemon-reload
systemctl enable --now wdtt
systemctl restart wdtt
trap - EXIT

# =========================================================================
# 9. Psiphon — binary, user, config
# =========================================================================

log "9/12 — Psiphon"
id psiphon >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin psiphon
mkdir -p /var/lib/psiphon /var/log/psiphon /etc/psiphon
chown -R psiphon:psiphon /var/lib/psiphon /var/log/psiphon
chmod 700 /var/lib/psiphon

# Always to the latest version. Download to a temp file and mv into place
# (atomic swap) instead of curl -o straight to the target path — that
# would rewrite the same inode, which is unsafe under a running process.
curl -fsSL -o /tmp/psiphon-tunnel-core.new \
  "https://raw.githubusercontent.com/Psiphon-Labs/psiphon-tunnel-core-binaries/master/linux/psiphon-tunnel-core-x86_64"
chmod 755 /tmp/psiphon-tunnel-core.new
mv /tmp/psiphon-tunnel-core.new /usr/local/bin/psiphon-tunnel-core

# Config — always a fresh template, but EgressRegion comes from the
# already-live file: the watchdog's rotation moves it, and a re-run
# shouldn't roll it back to whatever was passed in PSIPHON_EGRESS_REGION
# on the first run.
CURRENT_EGRESS_REGION="$PSIPHON_EGRESS_REGION"
if [ -f /etc/psiphon/psiphon.config ]; then
  CURRENT_EGRESS_REGION="$(python3 -c "
import json
print(json.load(open('/etc/psiphon/psiphon.config')).get('EgressRegion', '$PSIPHON_EGRESS_REGION'))
" 2>/dev/null || echo "$PSIPHON_EGRESS_REGION")"
fi
sed "s/REPLACE_WITH_EGRESS_REGION/${CURRENT_EGRESS_REGION}/" \
  "$REPO_DIR/psiphon.config" > /etc/psiphon/psiphon.config
chown root:psiphon /etc/psiphon/psiphon.config
chmod 640 /etc/psiphon/psiphon.config

cp "$REPO_DIR/psiphon.service" /etc/systemd/system/psiphon.service
systemctl daemon-reload
systemctl enable --now psiphon
systemctl restart psiphon

# =========================================================================
# 10. Psiphon watchdog
# =========================================================================

log "10/12 — Psiphon watchdog"
cp "$REPO_DIR/psiphon-watchdog.sh" /usr/local/sbin/psiphon-watchdog
cp "$REPO_DIR/psiphon-advance-region.sh" /usr/local/sbin/psiphon-advance-region
cp "$REPO_DIR/psiphon-gemini-check.sh" /usr/local/sbin/psiphon-gemini-check
chmod 755 /usr/local/sbin/psiphon-watchdog /usr/local/sbin/psiphon-advance-region /usr/local/sbin/psiphon-gemini-check

# Always a fresh template, but EGRESS_REGION and MIN_THROUGHPUT_KBPS are
# kept from the already-live file, if there was one — the first one moves
# with rotation, the second may have been deliberately calibrated for
# this particular node.
CURRENT_WD_EGRESS_REGION="$PSIPHON_EGRESS_REGION"
CURRENT_MIN_THROUGHPUT=""
if [ -f /etc/default/psiphon-watchdog ]; then
  CURRENT_WD_EGRESS_REGION="$(grep -oE '^EGRESS_REGION=.*' /etc/default/psiphon-watchdog | cut -d= -f2)"
  CURRENT_MIN_THROUGHPUT="$(grep -oE '^MIN_THROUGHPUT_KBPS=.*' /etc/default/psiphon-watchdog | cut -d= -f2)"
fi
sed "s/^EGRESS_REGION=.*/EGRESS_REGION=${CURRENT_WD_EGRESS_REGION}/" \
  "$REPO_DIR/psiphon-watchdog.default" > /etc/default/psiphon-watchdog
[ -n "$CURRENT_MIN_THROUGHPUT" ] && \
  sed -i "s/^MIN_THROUGHPUT_KBPS=.*/MIN_THROUGHPUT_KBPS=${CURRENT_MIN_THROUGHPUT}/" /etc/default/psiphon-watchdog

cp "$REPO_DIR/psiphon-watchdog.service" /etc/systemd/system/psiphon-watchdog.service
cp "$REPO_DIR/psiphon-watchdog.timer" /etc/systemd/system/psiphon-watchdog.timer
systemctl daemon-reload
systemctl enable --now psiphon-watchdog.timer

# =========================================================================
# 11. fail2ban
# =========================================================================

log "11/12 — fail2ban"
tmp_f2b="$(mktemp)"
sed "s/REPLACE_WITH_YOUR_SSH_PORT/${SSH_PORT}/" \
    "$REPO_DIR/fail2ban-setup.sh" > "$tmp_f2b"
bash "$tmp_f2b"
rm -f "$tmp_f2b"

# =========================================================================
# 12. Check and print client data
# =========================================================================

log "12/12 — check"

all_ok=1
for svc in nginx caddy-naive sing-box wdtt psiphon psiphon-watchdog.timer ufw fail2ban; do
  if systemctl is-active --quiet "$svc"; then
    echo "  OK   $svc"
  else
    echo "  FAIL $svc"
    all_ok=0
  fi
done

echo
echo "=== Reality/naive — client outbound configs (JSON) ==="
python3 - "$DOMAIN" "$SECRETS_FILE" <<'PYEOF'
import json, os, sys

domain, secrets_file = sys.argv[1], sys.argv[2]
env = {}
with open(secrets_file) as f:
    for line in f:
        line = line.strip()
        if not line or "=" not in line:
            continue
        k, v = line.split("=", 1)
        env[k] = v

for name in os.environ["CLIENT_NAMES"].split():
    uuid = env[f"CLIENT_{name}_UUID"]
    naive_pass = env[f"CLIENT_{name}_NAIVE_PASS"]
    config = {
        "outbounds": [
            {
                "type": "vless",
                "tag": "reality-out",
                "server": domain,
                "server_port": 443,
                "uuid": uuid,
                "flow": "xtls-rprx-vision",
                "tls": {
                    "enabled": True,
                    "server_name": domain,
                    "utls": {"enabled": True, "fingerprint": "chrome"},
                    "reality": {
                        "enabled": True,
                        "public_key": env["REALITY_PUBLIC_KEY"],
                        "short_id": env["SHORT_ID"],
                    },
                },
                "tcp_fast_open": True,
                "disable_tcp_keep_alive": True,
            },
            {
                "type": "naive",
                "tag": "naive-out",
                "server": domain,
                "server_port": 443,
                "username": name,
                "password": naive_pass,
                "tls": {"enabled": True, "server_name": domain},
                "tcp_fast_open": True,
                "disable_tcp_keep_alive": True,
            },
        ]
    }
    link = (f"vless://{uuid}@{domain}:443?encryption=none&security=reality&sni={domain}"
            f"&fp=chrome&pbk={env['REALITY_PUBLIC_KEY']}&sid={env['SHORT_ID']}"
            f"&type=tcp&flow=xtls-rprx-vision#{name}-reality")
    print(f"\n--- {name} ---")
    print(link)
    print(f"naive: username={name} password={naive_pass}")
    print(json.dumps(config, indent=2))
PYEOF

echo
echo "=== Managing clients, Psiphon, services ==="
echo "bash $REPO_DIR/manage.sh — interactive menu (add/remove a client,"
echo "change Psiphon's exit IP/region, status and restart of services)."

echo
echo "=== qWDTT — passwords (no vk_hash, enter the call links by hand) ==="
python3 -c "
import json
d = json.load(open('/etc/wdtt/passwords.json'))
for pw, entry in d['passwords'].items():
    print(f\"{entry['label']}: pass={pw}\")
"
echo "  peer=<server IP>:${WDTT_DTLS_PORT}, wg-port=${WDTT_WG_PORT}"

echo
if [ "$all_ok" = "1" ]; then
  echo "Done, all services are active."
else
  echo "WARNING: not all services are active, see FAIL above — journalctl -u <service>."
  exit 1
fi
