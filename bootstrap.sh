#!/usr/bin/env bash
# bootstrap.sh — stands up the whole stack on a clean VPS: sing-box
# (VLESS+Reality + naive), Caddy (naive camouflage + decoy), qWDTT
# (whitelist bypass via TPROXY), Psiphon (second egress for Google) +
# watchdog, firewall, base kernel hardening, fail2ban. Details — README.md
# next to this file.
#
# Deliberately not in here: SSH key setup/hardening (see SSH-HARDENING.md
# — needs a human watching a second session, easy to break beyond
# recovery otherwise) and adding any clients (see manage.sh — this script
# only ever stands up the infrastructure, with nobody authorized to use
# it yet; add the first person with manage.sh once this finishes).
#
# Every value below comes only from an env var, or — missing that — from
# whatever this VPS is already running. Never from an interactive
# prompt: a human-friendly first run belongs in install.sh, which asks
# what it needs and then calls this script with everything resolved.
# This one stays a plain, predictable function of its inputs, so a
# re-run (update) on an already-configured server needs none of them
# spelled out again.

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# =========================================================================
# CONFIG
# =========================================================================

SING_BOX_CONFIG_PATH=/etc/sing-box/config.json
PSIPHON_CONFIG_PATH=/etc/psiphon/psiphon.config

if [ -z "${DOMAIN:-}" ] && [ -f "$SING_BOX_CONFIG_PATH" ]; then
  # Reads back what this script itself wrote last time, matched by tag
  # rather than inbound position — so reordering inbounds later can't
  # silently break this.
  DOMAIN="$(python3 -c "
import json
d = json.load(open('$SING_BOX_CONFIG_PATH'))
for i in d['inbounds']:
    if i['tag'] == 'vless-reality-in':
        print(i['tls']['server_name'])
        break
" 2>/dev/null || true)"
fi
DOMAIN="${DOMAIN:?set DOMAIN=your.domain (its A record must already point at this VPS)}"

if [ -z "${SSH_PORT:-}" ]; then
  # What sshd actually listens on right now — set up by hand per
  # SSH-HARDENING.md before this script ever runs. Reading the live
  # process rather than parsing sshd_config text: a config with no
  # explicit Port line (meaning the default, 22) would otherwise look
  # like nothing is configured at all, when the real answer is "22".
  SSH_PORT="$(ss -tlnp 2>/dev/null | grep sshd \
    | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]+|\[.*\]:[0-9]+' \
    | grep -oE '[0-9]+$' | sort -u | head -1)"
fi
SSH_PORT="${SSH_PORT:?set SSH_PORT=number (the one already configured in sshd_config)}"

if [ -z "${PSIPHON_EGRESS_REGION:-}" ] && [ -f "$PSIPHON_CONFIG_PATH" ]; then
  # The watchdog's own rotation can move this — read the live value
  # rather than rolling it back to whatever was passed before.
  PSIPHON_EGRESS_REGION="$(python3 -c "import json; print(json.load(open('$PSIPHON_CONFIG_PATH')).get('EgressRegion',''))" 2>/dev/null || true)"
fi
PSIPHON_EGRESS_REGION="${PSIPHON_EGRESS_REGION:?set PSIPHON_EGRESS_REGION=NL (two-letter code; Psiphon itself prints the full list to its log on first run, AvailableEgressRegions)}"

# EMAIL is only ever used to issue a *new* certificate — nothing reads it
# back, so there's nothing to detect. Required only when we're actually
# about to call real certbot (not SKIP_CERTBOT, and no cert yet for
# DOMAIN); a re-run with an existing cert needs it even less than the
# others above.
if [ "${SKIP_CERTBOT:-0}" != "1" ] && [ ! -d "/etc/letsencrypt/live/${DOMAIN}" ]; then
  EMAIL="${EMAIL:?set EMAIL=your@email (used only for issuing the certificate)}"
fi

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
#    an explicit restart below) + server-wide Reality keys (generated
#    once, read after — a re-run never touches them)
# =========================================================================

log "updating sing-box to the latest version"
bash <(curl -fsSL https://sing-box.app/install.sh) >/dev/null

if [ -f "$SECRETS_FILE" ]; then
  log "Secrets already generated ($SECRETS_FILE) — reusing"
  # shellcheck disable=SC1090
  . "$SECRETS_FILE"
else
  log "First run — generating Reality keys"
  REALITY_KEYS="$(sing-box generate reality-keypair)"
  REALITY_PRIVATE_KEY="$(echo "$REALITY_KEYS" | grep PrivateKey | awk '{print $2}')"
  REALITY_PUBLIC_KEY="$(echo "$REALITY_KEYS" | grep PublicKey | awk '{print $2}')"
  SHORT_ID="$(sing-box generate rand --hex 8)"

  {
    echo "REALITY_PRIVATE_KEY=$REALITY_PRIVATE_KEY"
    echo "REALITY_PUBLIC_KEY=$REALITY_PUBLIC_KEY"
    echo "SHORT_ID=$SHORT_ID"
  } > "$SECRETS_FILE"
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

# A deliberate domain change leaves the old certificate behind, otherwise
# unnoticed — never deleted automatically (Let's Encrypt only allows 5
# issuances per domain per week, so an automatic delete could cost a
# real retry later if the change ever gets reverted), just pointed out.
if [ -d /etc/letsencrypt/live ]; then
  for cert_dir in /etc/letsencrypt/live/*/; do
    cert_name="$(basename "$cert_dir")"
    if [ "$cert_name" != "$DOMAIN" ]; then
      echo "NOTE: found a certificate for '${cert_name}', no longer matching DOMAIN=${DOMAIN}."
      echo "      If you're done with it: certbot delete --cert-name ${cert_name}"
    fi
  done
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
# deployment, hence the separate call here. Reads naive credentials
# straight out of sing-box's own config (see step 6 below for why that's
# the one source of truth for clients now), so it always matches exactly
# who sing-box will actually accept, first run or re-run alike.
python3 "$REPO_DIR/regen-caddyfile.py" "$DOMAIN" "$SING_BOX_CONFIG_PATH" /etc/caddy/Caddyfile

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

python3 - "$DOMAIN" "$SECRETS_FILE" "$WDTT_TPROXY_PORT" "$SING_BOX_CONFIG_PATH" <<'PYEOF'
import json, sys

domain, secrets_file, tproxy_port, config_path = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]

env = {}
with open(secrets_file) as f:
    for line in f:
        line = line.strip()
        if not line or "=" not in line:
            continue
        k, v = line.split("=", 1)
        env[k] = v

# Clients are managed exclusively through manage.sh, never here — a
# re-run carries the existing user lists forward untouched instead of
# rebuilding them from any name list, so this script never needs to
# know who they are. A first run (no config yet) starts both empty:
# nobody is authorized until manage.sh adds them.
vless_users, naive_users = [], []
try:
    old = json.load(open(config_path))
    for i in old.get("inbounds", []):
        if i.get("tag") == "vless-reality-in":
            vless_users = i.get("users", [])
        elif i.get("tag") == "naive-in":
            naive_users = i.get("users", [])
except FileNotFoundError:
    pass

# naive-in only exists once it has users — sing-box refuses an empty
# naive inbound ("missing users"), unlike vless-reality-in. manage.sh
# creates/drops it as the first/last naive client comes or goes.
inbounds = [
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
]
if naive_users:
    inbounds.append({
        "type": "naive",
        "tag": "naive-in",
        "listen": "127.0.0.1",
        "listen_port": 1080,
        "network": "tcp",
        "users": naive_users,
    })
inbounds.append({
    "type": "tproxy",
    "tag": "wdtt-tproxy-in",
    "listen": "0.0.0.0",
    "listen_port": tproxy_port,
})

config = {
    "log": {"level": "warn", "output": "/var/log/sing-box/box.log", "timestamp": True},
    "dns": {
        "servers": [{"type": "https", "tag": "doh", "server": "1.1.1.1", "server_port": 443}],
        "strategy": "ipv4_only",
    },
    "inbounds": inbounds,
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

json.dump(config, open(config_path, "w"), indent=2)
print(f"sing-box config.json written ({len(vless_users)} Reality, {len(naive_users)} naive user(s) carried forward)")
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
  python3 -c "
import json
db = {
    'main_password': '',
    'admin_id': '',
    'bot_token': '',
    'passwords': {},
    'devices': {},
}
json.dump(db, open('/etc/wdtt/passwords.json', 'w'), indent=2)
print('passwords.json written, empty — add qWDTT clients with manage.sh.')
"
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
# Same problem as naive-in: wdtt-server exits immediately with zero
# passwords configured ("no active passwords for WRAP"). Leave it
# stopped until manage.sh adds the first one.
if python3 -c "import json,sys; sys.exit(0 if json.load(open('/etc/wdtt/passwords.json'))['passwords'] else 1)"; then
  systemctl enable --now wdtt
  systemctl restart wdtt
else
  log "no qWDTT clients yet — leaving wdtt stopped"
  systemctl disable wdtt 2>/dev/null || true
  systemctl stop wdtt 2>/dev/null || true
fi
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

# Config — always a fresh template. PSIPHON_EGRESS_REGION was already
# resolved to the live file's current value above (if there was one),
# so a re-run can't roll back what the watchdog's rotation has moved.
sed "s/REPLACE_WITH_EGRESS_REGION/${PSIPHON_EGRESS_REGION}/" \
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
cp "$REPO_DIR/singbox-google-route.sh" /usr/local/sbin/singbox-google-route
chmod 755 /usr/local/sbin/psiphon-watchdog /usr/local/sbin/psiphon-advance-region \
  /usr/local/sbin/psiphon-gemini-check /usr/local/sbin/singbox-google-route

# Always a fresh template. EGRESS_REGION uses the same already-resolved
# PSIPHON_EGRESS_REGION as psiphon.config above (they're meant to always
# match). MIN_THROUGHPUT_KBPS is the one value here with no equivalent
# upstream to resolve from — kept from the live file if it was ever
# calibrated away from the template's default.
CURRENT_MIN_THROUGHPUT=""
if [ -f /etc/default/psiphon-watchdog ]; then
  CURRENT_MIN_THROUGHPUT="$(grep -oE '^MIN_THROUGHPUT_KBPS=.*' /etc/default/psiphon-watchdog | cut -d= -f2)"
fi
sed "s/^EGRESS_REGION=.*/EGRESS_REGION=${PSIPHON_EGRESS_REGION}/" \
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
# 12. Check
# =========================================================================

log "12/12 — check"

all_ok=1
for svc in nginx caddy-naive sing-box wdtt psiphon psiphon-watchdog.timer ufw fail2ban; do
  if [ "$svc" = "wdtt" ] && ! systemctl is-enabled --quiet wdtt 2>/dev/null; then
    echo "  --   wdtt (no qWDTT clients yet)"
    continue
  fi
  if systemctl is-active --quiet "$svc"; then
    echo "  OK   $svc"
  else
    echo "  FAIL $svc"
    all_ok=0
  fi
done

echo
echo "=== Managing clients, Psiphon, services ==="
echo "bash $REPO_DIR/manage.sh — interactive menu (add/remove a client,"
echo "change Psiphon's exit IP/region, status and restart of services)."
echo "No clients are authorized yet on a first run — add the first one there."

echo
if [ "$all_ok" = "1" ]; then
  # Stamped only on a fully successful run — the file is meant to record
  # what's actually running, not what a half-failed attempt tried to
  # deploy. manage.sh and a future install.sh read this to warn before
  # updating across a MAJOR version — see CHANGELOG.md for what that means.
  cp "$REPO_DIR/VERSION" /etc/vps-bootstrap-version
  echo "Done, all services are active. (version $(cat "$REPO_DIR/VERSION"))"
else
  echo "WARNING: not all services are active, see FAIL above — journalctl -u <service>."
  exit 1
fi
