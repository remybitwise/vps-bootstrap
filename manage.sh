#!/usr/bin/env bash
# manage.sh — interactive server-management menu: clients (Reality/
# naive/qWDTT, independently), Psiphon status/exit-IP/region, service
# status/restart, and updating binaries without a full bootstrap.sh run.
#
# Self-contained, no sibling scripts — except psiphon-advance-region,
# already part of the deployed watchdog, so not duplicated here.
#
# No `set -e` at the top level: this is an interactive loop, one failed
# operation shouldn't kill the menu. Each operation runs in its own
# `(set -e; ...)` subshell instead.

C_BOLD=$'\033[1m'; C_CYAN=$'\033[1;36m'; C_GREEN=$'\033[1;32m'; C_RED=$'\033[1;31m'; C_YELLOW=$'\033[1;33m'; C_RESET=$'\033[0m'

SECRETS_FILE="/root/.vps-bootstrap-secrets.env"
SING_BOX_CONFIG=/etc/sing-box/config.json
CADDYFILE=/etc/caddy/Caddyfile
WDTT_CONFIG=/etc/wdtt/passwords.json
WDTT_SERVICE=/etc/systemd/system/wdtt.service
PSIPHON_DEFAULT=/etc/default/psiphon-watchdog
PSIPHON_CONFIG=/etc/psiphon/psiphon.config
VERSION_FILE=/etc/vps-bootstrap-version

[ "$(id -u)" = "0" ] || { echo "ERROR: run as root"; exit 1; }

deployed_version() {
  cat "$VERSION_FILE" 2>/dev/null || echo "unknown (no $VERSION_FILE — deployed before versioning, or bootstrap.sh never finished cleanly)"
}

domain() {
  python3 -c "
import json
d = json.load(open('$SING_BOX_CONFIG'))
for i in d['inbounds']:
    if i['tag'] == 'vless-reality-in':
        print(i['tls']['server_name'])
        break
" 2>/dev/null || echo "?"
}

# =========================================================================
# Clients — queries
# =========================================================================

has_reality() {
  python3 -c "
import json, sys
d = json.load(open('$SING_BOX_CONFIG'))
names = {u['name'] for i in d['inbounds'] if i['tag'] == 'vless-reality-in' for u in i['users']}
sys.exit(0 if '$1' in names else 1)
" 2>/dev/null
}

has_naive() {
  python3 -c "
import json, sys
d = json.load(open('$SING_BOX_CONFIG'))
names = {u['username'] for i in d['inbounds'] if i['tag'] == 'naive-in' for u in i['users']}
sys.exit(0 if '$1' in names else 1)
" 2>/dev/null
}

has_wdtt() {
  [ -f "$WDTT_CONFIG" ] && python3 -c "
import json, sys
d = json.load(open('$WDTT_CONFIG'))
sys.exit(0 if any(v.get('label') == '$1' for v in d['passwords'].values()) else 1)
" 2>/dev/null
}

list_clients() {
  echo "=== Reality / naive ==="
  python3 -c "
import json
d = json.load(open('$SING_BOX_CONFIG'))
reality = {u['name'] for i in d['inbounds'] if i['tag']=='vless-reality-in' for u in i['users']}
naive = {u['username'] for i in d['inbounds'] if i['tag']=='naive-in' for u in i['users']}
direct = {r['user'][0] for r in d['route']['rules'] if r.get('outbound') == 'direct' and r.get('user')}
for name in sorted(reality | naive):
    tags = []
    if name in reality: tags.append('reality')
    if name in naive: tags.append('naive')
    if name in direct: tags.append('google-direct')
    print(f'  {name}: {\",\".join(tags)}')
" 2>/dev/null || echo "  (failed to read $SING_BOX_CONFIG)"

  echo
  echo "=== qWDTT ==="
  if [ -f "$WDTT_CONFIG" ]; then
    python3 -c "
import json
d = json.load(open('$WDTT_CONFIG'))
for v in d['passwords'].values():
    vk = 'yes' if v.get('vk_hash') else 'NO'
    dev = 'bound' if v.get('device_id') else 'not bound'
    print(f\"  {v['label']}: vk_hash={vk}, device={dev}\")
"
  else
    echo "  (qWDTT is not configured on this server)"
  fi
}

ask_yn() {
  # ask_yn "prompt" default_letter -> echoes 1 or 0
  local prompt="$1" default="$2" ans
  read -rp "$prompt " ans
  ans=${ans:-$default}
  [[ "$ans" =~ ^[Yy]$ ]] && echo 1 || echo 0
}

# =========================================================================
# Caddyfile — rebuilt straight from sing-box's own naive-in.users, so it
# always matches what sing-box will actually accept (single source of
# truth, no separate file to keep in sync).
# =========================================================================

regen_caddyfile() {
  local domain_name="$1"
  python3 - "$domain_name" "$SING_BOX_CONFIG" "$CADDYFILE" <<'PYEOF'
import base64, json, re, sys

domain, config_path, caddyfile_path = sys.argv[1:4]
d = json.load(open(config_path))
naive_users = next((i["users"] for i in d["inbounds"] if i["tag"] == "naive-in"), [])

b64_headers = [
    # re.escape: see regen-caddyfile.py for why — same construction, same
    # one-line defensive escape against an unusual client name.
    re.escape(base64.b64encode(f"{u['username']}:{u['password']}".encode()).decode())
    for u in naive_users
]
pattern = "|".join(b64_headers)

caddyfile = f'''{{
	admin off
	auto_https off
	log {{
		exclude http.log.error
	}}
}}

:8446 {{
	bind 127.0.0.1
	tls /etc/letsencrypt/live/{domain}/fullchain.pem /etc/letsencrypt/live/{domain}/privkey.pem
	encode
	header -Server
	header -Alt-Svc

	@naive {{
		method CONNECT
		header_regexp Proxy-Authorization "^Basic ({pattern})$"
	}}
	handle @naive {{
		reverse_proxy 127.0.0.1:1080 {{
			transport http {{
				versions h2c
			}}
			header_up Proxy-Authorization {{http.request.header.Proxy-Authorization}}
		}}
	}}
	handle {{
		root * /var/www/html
		file_server
	}}
}}
'''
open(caddyfile_path, "w").write(caddyfile)
print("Caddyfile written for:", sorted(u["username"] for u in naive_users))
PYEOF
  chown caddy:caddy "$CADDYFILE"
  chmod 600 "$CADDYFILE"
  caddy validate --config "$CADDYFILE" --adapter caddyfile
  systemctl restart caddy-naive
}

# =========================================================================
# Clients — Reality / naive mutations
# =========================================================================

_do_add_reality_naive() {
  set -euo pipefail
  local name="$1" do_reality="$2" do_naive="$3"

  if [ "$do_reality" = 1 ] && has_reality "$name"; then
    echo "'$name' already has Reality — skipping that part."
    do_reality=0
  fi
  if [ "$do_naive" = 1 ] && has_naive "$name"; then
    echo "'$name' already has naive — skipping that part."
    do_naive=0
  fi
  if [ "$do_reality" = 0 ] && [ "$do_naive" = 0 ]; then
    echo "Nothing left to add."
    return 0
  fi

  if [ "$do_reality" = 1 ] && grep -q "^CLIENT_${name}_UUID=" "$SECRETS_FILE" 2>/dev/null; then
    echo "ERROR: $SECRETS_FILE already has CLIENT_${name}_UUID, but sing-box config does not list"
    echo "'$name' under Reality — config/secrets have drifted apart. Fix that by hand before retrying."
    return 1
  fi
  if [ "$do_naive" = 1 ] && grep -q "^CLIENT_${name}_NAIVE_PASS=" "$SECRETS_FILE" 2>/dev/null; then
    echo "ERROR: $SECRETS_FILE already has CLIENT_${name}_NAIVE_PASS, but sing-box config does not"
    echo "list '$name' under naive — config/secrets have drifted apart. Fix that by hand before retrying."
    return 1
  fi

  local new_uuid="" new_naive_pass=""
  if [ "$do_reality" = 1 ]; then
    new_uuid="$(sing-box generate uuid)"
    echo "CLIENT_${name}_UUID=$new_uuid" >> "$SECRETS_FILE"
  fi
  if [ "$do_naive" = 1 ]; then
    new_naive_pass="$(openssl rand -base64 24)"
    echo "CLIENT_${name}_NAIVE_PASS=$new_naive_pass" >> "$SECRETS_FILE"
  fi

  local backup
  backup="${SING_BOX_CONFIG}.bak-$(date +%s)"
  cp "$SING_BOX_CONFIG" "$backup"

  python3 - "$name" "$do_reality" "$new_uuid" "$do_naive" "$new_naive_pass" "$SING_BOX_CONFIG" <<'PYEOF'
import json, sys
name, do_reality, uuid, do_naive, naive_pass, config_path = sys.argv[1:7]
d = json.load(open(config_path))
for i in d["inbounds"]:
    if do_reality == "1" and i["tag"] == "vless-reality-in":
        i["users"].append({"name": name, "uuid": uuid, "flow": "xtls-rprx-vision"})
if do_naive == "1":
    # naive-in may not exist yet — see bootstrap.sh for why.
    naive_in = next((i for i in d["inbounds"] if i["tag"] == "naive-in"), None)
    if naive_in is None:
        naive_in = {
            "type": "naive", "tag": "naive-in", "listen": "127.0.0.1",
            "listen_port": 1080, "network": "tcp", "users": [],
        }
        d["inbounds"].append(naive_in)
    naive_in["users"].append({"username": name, "password": naive_pass})
json.dump(d, open(config_path, "w"), indent=2, ensure_ascii=False)
PYEOF

  if ! sing-box check -c "$SING_BOX_CONFIG"; then
    echo "ERROR: sing-box check failed, restoring $backup"
    cp "$backup" "$SING_BOX_CONFIG"
    return 1
  fi
  systemctl restart sing-box

  if [ "$do_naive" = 1 ]; then
    cp "$CADDYFILE" "${CADDYFILE}.bak-$(date +%s)"
    regen_caddyfile "$(domain)"
  fi

  echo
  echo "=== '$name' — done ==="
  if [ "$do_reality" = 1 ]; then
    local pub sid
    pub="$(grep '^REALITY_PUBLIC_KEY=' "$SECRETS_FILE" | cut -d= -f2)"
    sid="$(grep '^SHORT_ID=' "$SECRETS_FILE" | cut -d= -f2)"
    echo "vless://${new_uuid}@$(domain):443?encryption=none&security=reality&sni=$(domain)&fp=chrome&pbk=${pub}&sid=${sid}&type=tcp&flow=xtls-rprx-vision#${name}-reality"
  fi
  if [ "$do_naive" = 1 ]; then
    echo "naive: username=$name password=$new_naive_pass"
  fi
}

add_reality_naive() {
  ( _do_add_reality_naive "$1" "$2" "$3" ) || echo "Failed to add Reality/naive for '$1' — see output above."
}

_do_remove_reality_naive() {
  set -euo pipefail
  local name="$1" do_reality="$2" do_naive="$3"

  if [ "$do_reality" = 1 ] && ! has_reality "$name"; then
    do_reality=0
  fi
  if [ "$do_naive" = 1 ] && ! has_naive "$name"; then
    do_naive=0
  fi

  if [ "$do_reality" = 0 ] && [ "$do_naive" = 0 ]; then
    echo "'$name' was not found in the requested service(s) — nothing to remove."
    return 0
  fi

  local backup
  backup="${SING_BOX_CONFIG}.bak-$(date +%s)"
  cp "$SING_BOX_CONFIG" "$backup"

  python3 - "$name" "$do_reality" "$do_naive" "$SING_BOX_CONFIG" <<'PYEOF'
import json, sys
name, do_reality, do_naive, config_path = sys.argv[1:5]
d = json.load(open(config_path))
for i in d["inbounds"]:
    if do_reality == "1" and i["tag"] == "vless-reality-in":
        i["users"] = [u for u in i["users"] if u.get("name") != name]
    if do_naive == "1" and i["tag"] == "naive-in":
        i["users"] = [u for u in i["users"] if u.get("username") != name]
# drop naive-in if that just emptied it (see _do_add_reality_naive)
d["inbounds"] = [i for i in d["inbounds"] if not (i["tag"] == "naive-in" and not i["users"])]
json.dump(d, open(config_path, "w"), indent=2, ensure_ascii=False)
PYEOF

  if ! sing-box check -c "$SING_BOX_CONFIG"; then
    echo "ERROR: sing-box check failed, restoring $backup"
    cp "$backup" "$SING_BOX_CONFIG"
    return 1
  fi
  systemctl restart sing-box

  if [ "$do_reality" = 1 ]; then
    sed -i "/^CLIENT_${name}_UUID=/d" "$SECRETS_FILE"
  fi
  if [ "$do_naive" = 1 ]; then
    sed -i "/^CLIENT_${name}_NAIVE_PASS=/d" "$SECRETS_FILE"
  fi

  if [ "$do_naive" = 1 ]; then
    cp "$CADDYFILE" "${CADDYFILE}.bak-$(date +%s)"
    regen_caddyfile "$(domain)"
  fi

  local parts=()
  if [ "$do_reality" = 1 ]; then
    parts+=("Reality")
  fi
  if [ "$do_naive" = 1 ]; then
    parts+=("naive")
  fi
  echo "=== '$name' removed from: ${parts[*]} ==="
}

remove_reality_naive() {
  ( _do_remove_reality_naive "$1" "$2" "$3" ) || echo "Failed to remove Reality/naive for '$1' — see output above."
}

# =========================================================================
# Clients — qWDTT mutations
# =========================================================================

_do_add_wdtt() {
  set -euo pipefail
  local name="$1"

  [ -f "$WDTT_CONFIG" ] || { echo "ERROR: $WDTT_CONFIG not found"; return 1; }
  if has_wdtt "$name"; then
    echo "'$name' already has qWDTT — skipping."
    return 0
  fi

  local new_pass
  new_pass="$(python3 -c "
import secrets, string
print(''.join(secrets.choice(string.ascii_letters + string.digits) for _ in range(23)))
")"

  echo "Stopping wdtt before editing passwords.json (otherwise there's a race with its own autosave)..."
  systemctl stop wdtt

  cp "$WDTT_CONFIG" "${WDTT_CONFIG}.bak-$(date +%s)"
  python3 - "$name" "$new_pass" "$WDTT_CONFIG" <<'PYEOF'
import json, sys
name, password, config_path = sys.argv[1:4]
d = json.load(open(config_path))
d["passwords"][password] = {
    "label": name,
    "device_id": "",
    "device_ids": [],
    "max_devices": 1,
    "expires_at": 0,
    "down_bytes": 0,
    "up_bytes": 0,
}
json.dump(d, open(config_path, "w"), indent=2)
PYEOF
  chown wdtt:wdtt "$WDTT_CONFIG"
  chmod 600 "$WDTT_CONFIG"

  # enable, not just start: may be disabled (see bootstrap.sh)
  systemctl enable --now wdtt
  systemctl restart wdtt
  sleep 1
  if ! systemctl is-active --quiet wdtt; then
    echo "ERROR: wdtt did not come back up, check journalctl -u wdtt"
    return 1
  fi

  local dtls_port wg_port public_ip
  dtls_port="$(grep -oE -- '-listen [0-9.]+:[0-9]+' "$WDTT_SERVICE" | grep -oE '[0-9]+$')"
  wg_port="$(grep -oE -- '-wg-port [0-9]+' "$WDTT_SERVICE" | grep -oE '[0-9]+$')"
  public_ip="$(curl -s --max-time 10 https://api.ipify.org || echo '?')"

  echo
  echo "=== '$name' — qWDTT ready ==="
  echo "password=$new_pass"
  echo "peer=${public_ip}:${dtls_port}  wg-port=${wg_port}"
  echo
  echo "vk_hash is NOT set — create a regular VK group video call for $name,"
  echo "grab the hash from the call link, and enter it by hand into"
  echo "$WDTT_CONFIG, in the vk_hash field of the entry with password=$new_pass."
}

add_wdtt() {
  ( _do_add_wdtt "$1" ) || echo "Failed to add qWDTT for '$1' — see output above."
}

_do_remove_wdtt() {
  set -euo pipefail
  local name="$1"

  if ! has_wdtt "$name"; then
    echo "'$name' not found in qWDTT — skipping."
    return 0
  fi

  echo "Stopping wdtt before editing passwords.json..."
  systemctl stop wdtt
  cp "$WDTT_CONFIG" "${WDTT_CONFIG}.bak-$(date +%s)"
  python3 -c "
import json
d = json.load(open('$WDTT_CONFIG'))
d['passwords'] = {k: v for k, v in d['passwords'].items() if v.get('label') != '$name'}
json.dump(d, open('$WDTT_CONFIG', 'w'), indent=2)
"
  chown wdtt:wdtt "$WDTT_CONFIG"
  chmod 600 "$WDTT_CONFIG"
  # stay stopped if that was the last password (see bootstrap.sh)
  if python3 -c "import json,sys; sys.exit(0 if json.load(open('$WDTT_CONFIG'))['passwords'] else 1)"; then
    systemctl start wdtt
  else
    systemctl disable wdtt 2>/dev/null || true
  fi
  echo "'$name' removed from qWDTT."
}

remove_wdtt() {
  ( _do_remove_wdtt "$1" ) || echo "Failed to remove qWDTT for '$1' — see output above."
}

# =========================================================================
# Clients — top-level add/remove flows
# =========================================================================

add_client() {
  read -rp "New client name: " name
  [ -z "$name" ] && { echo "Empty name, aborting."; return; }

  local add_reality add_naive add_wdtt_flag
  add_reality=$(ask_yn "Add Reality? [Y/n]" Y)
  add_naive=$(ask_yn "Add naive? [Y/n]" Y)
  add_wdtt_flag=$(ask_yn "Add qWDTT? [y/N]" N)

  if [ "$add_reality" = 1 ] || [ "$add_naive" = 1 ]; then
    add_reality_naive "$name" "$add_reality" "$add_naive"
  fi
  [ "$add_wdtt_flag" = 1 ] && add_wdtt "$name"
}

remove_client() {
  read -rp "Client name to remove from: " name
  [ -z "$name" ] && { echo "Empty name, aborting."; return; }

  local rm_reality rm_naive rm_wdtt_flag
  rm_reality=$(ask_yn "Remove Reality? [Y/n]" Y)
  rm_naive=$(ask_yn "Remove naive? [Y/n]" Y)
  rm_wdtt_flag=$(ask_yn "Remove qWDTT? [Y/n]" Y)

  if [ "$rm_reality" = 1 ] || [ "$rm_naive" = 1 ]; then
    remove_reality_naive "$name" "$rm_reality" "$rm_naive"
  fi
  [ "$rm_wdtt_flag" = 1 ] && remove_wdtt "$name"
}

show_client_config() {
  local name
  read -rp "Client name: " name
  [ -z "$name" ] && { echo "Empty name, aborting."; return; }

  local has_r=0 has_n=0 has_w=0
  has_reality "$name" && has_r=1
  has_naive "$name" && has_n=1
  has_wdtt "$name" && has_w=1
  if [ "$has_r" = 0 ] && [ "$has_n" = 0 ] && [ "$has_w" = 0 ]; then
    echo "'$name' not found in Reality, naive, or qWDTT."
    return
  fi

  echo "Show:"
  echo "  1) Everything (links + JSON) [default]"
  echo "  2) Links only"
  echo "  3) JSON only (Reality/naive — qWDTT has no JSON form)"
  local fmt show_links=1 show_json=1
  read -rp "> " fmt
  case "$fmt" in
    2) show_json=0 ;;
    3) show_links=0 ;;
  esac

  local d; d="$(domain)"
  local uuid="" pub="" sid="" naive_pass=""

  if [ "$has_r" = 1 ]; then
    uuid="$(grep "^CLIENT_${name}_UUID=" "$SECRETS_FILE" | cut -d= -f2)"
    pub="$(grep '^REALITY_PUBLIC_KEY=' "$SECRETS_FILE" | cut -d= -f2)"
    sid="$(grep '^SHORT_ID=' "$SECRETS_FILE" | cut -d= -f2)"
    if [ "$show_links" = 1 ]; then
      echo
      echo "${C_CYAN}=== '$name' — Reality ===${C_RESET}"
      echo "vless://${uuid}@${d}:443?encryption=none&security=reality&sni=${d}&fp=chrome&pbk=${pub}&sid=${sid}&type=tcp&flow=xtls-rprx-vision#${name}-reality"
    fi
  fi

  if [ "$has_n" = 1 ]; then
    naive_pass="$(grep "^CLIENT_${name}_NAIVE_PASS=" "$SECRETS_FILE" | cut -d= -f2)"
    if [ "$show_links" = 1 ]; then
      echo
      echo "${C_CYAN}=== '$name' — naive ===${C_RESET}"
      echo "username=$name password=$naive_pass"
    fi
  fi

  if [ "$show_json" = 1 ] && { [ "$has_r" = 1 ] || [ "$has_n" = 1 ]; }; then
    echo
    echo "${C_CYAN}=== '$name' — sing-box config ===${C_RESET}"
    python3 - "$d" "$has_r" "$uuid" "$pub" "$sid" "$has_n" "$name" "$naive_pass" <<'PYEOF'
import json, sys
domain, has_r, uuid, pub, sid, has_n, username, naive_pass = sys.argv[1:9]
outbounds = []
if has_r == "1":
    outbounds.append({
        "type": "vless", "tag": "proxy-reality",
        "server": domain, "server_port": 443,
        "uuid": uuid, "flow": "xtls-rprx-vision",
        "tls": {
            "enabled": True, "server_name": domain,
            "utls": {"enabled": True, "fingerprint": "chrome"},
            "reality": {"enabled": True, "public_key": pub, "short_id": sid},
        },
    })
if has_n == "1":
    outbounds.append({
        "type": "naive", "tag": "proxy-naive",
        "server": domain, "server_port": 443,
        "username": username, "password": naive_pass,
        "tls": {"enabled": True, "server_name": domain},
    })
print(json.dumps({"outbounds": outbounds}, indent=2))
PYEOF
  fi

  if [ "$has_w" = 1 ]; then
    local wdtt_pass vk_hash dtls_port wg_port public_ip
    read -r wdtt_pass vk_hash <<<"$(python3 - "$name" "$WDTT_CONFIG" <<'PYEOF'
import json, sys
name, config_path = sys.argv[1:3]
d = json.load(open(config_path))
for password, rec in d.get("passwords", {}).items():
    if rec.get("label") == name:
        print(password, rec.get("vk_hash") or "-")
        break
PYEOF
)"
    dtls_port="$(grep -oE -- '-listen [0-9.]+:[0-9]+' "$WDTT_SERVICE" | grep -oE '[0-9]+$')"
    wg_port="$(grep -oE -- '-wg-port [0-9]+' "$WDTT_SERVICE" | grep -oE '[0-9]+$')"
    public_ip="$(curl -s --max-time 10 https://api.ipify.org || echo '?')"
    [ "$vk_hash" = "-" ] && vk_hash=""

    echo
    echo "${C_CYAN}=== '$name' — qWDTT ===${C_RESET}"
    # Only wdtt:// (iOS) needs vk_hash as a positional field — qwdtt://
    # (Android) works without one, auto-joins a call in anonymous mode.
    echo "wdtt://${public_ip}:${dtls_port}:${wg_port}:9000:${wdtt_pass}:${vk_hash}"
    [ -z "$vk_hash" ] && echo "(no vk_hash set — wdtt:// needs one, add it in $WDTT_CONFIG; qwdtt:// below works without it)"
    echo
    python3 - "$name" "$public_ip" "$dtls_port" "$vk_hash" "$wdtt_pass" <<'PYEOF'
import sys
from urllib.parse import quote
name, ip, dtls_port, vk_hash, password = sys.argv[1:6]
link = f"qwdtt://config?name={quote(name)}&peer={quote(f'{ip}:{dtls_port}')}"
if vk_hash:
    link += f"&hashes={quote(vk_hash)}"
link += f"&workers=18&port=9000&pass={quote(password)}"
print(link)
PYEOF
  fi
}

has_direct_route() {
  grep -q "^CLIENT_${1}_ROUTE=direct$" "$SECRETS_FILE" 2>/dev/null
}

_do_toggle_direct_route() {
  set -euo pipefail
  local name="$1" backup turning_on=1
  has_direct_route "$name" && turning_on=0

  # Secrets first, same order as _do_add_reality_naive/_do_remove_reality_naive —
  # if systemctl restart below fails, secrets and config.json still agree
  # with each other instead of drifting apart.
  if [ "$turning_on" = 1 ]; then
    echo "CLIENT_${name}_ROUTE=direct" >> "$SECRETS_FILE"
  else
    sed -i "/^CLIENT_${name}_ROUTE=direct\$/d" "$SECRETS_FILE"
  fi

  backup="${SING_BOX_CONFIG}.bak-$(date +%s)"
  cp "$SING_BOX_CONFIG" "$backup"
  python3 - "$name" "$turning_on" "$SING_BOX_CONFIG" <<'PYEOF'
import json, sys
name, turning_on, config_path = sys.argv[1], sys.argv[2] == "1", sys.argv[3]
d = json.load(open(config_path))
if turning_on:
    rules = d["route"]["rules"]
    idx = next((i for i, r in enumerate(rules) if "rule_set" in r), len(rules))
    rules.insert(idx, {
        "user": [name], "rule_set": ["google-geosite", "google-geoip"],
        "action": "route", "outbound": "direct",
    })
else:
    d["route"]["rules"] = [
        r for r in d["route"]["rules"]
        if not (r.get("outbound") == "direct" and r.get("user") == [name])
    ]
json.dump(d, open(config_path, "w"), indent=2, ensure_ascii=False)
PYEOF

  if ! sing-box check -c "$SING_BOX_CONFIG"; then
    echo "ERROR: sing-box check failed, restoring $backup"
    cp "$backup" "$SING_BOX_CONFIG"
    return 1
  fi
  systemctl restart sing-box

  if [ "$turning_on" = 1 ]; then
    echo "'$name': Google/YouTube now always direct, ignoring the Psiphon switch."
  else
    echo "'$name': Google/YouTube back to the normal Psiphon switch."
  fi
}

toggle_direct_route() {
  read -rp "Client name: " name
  [ -z "$name" ] && { echo "Empty name, aborting."; return; }
  if ! has_reality "$name" && ! has_naive "$name"; then
    echo "'$name' has no Reality or naive client."
    return
  fi
  ( _do_toggle_direct_route "$name" ) || echo "Failed to toggle direct routing for '$name' — see output above."
}

# =========================================================================
# Psiphon
# =========================================================================

socks_port() {
  grep -oE '^SOCKS_PORT=[0-9]+' "$PSIPHON_DEFAULT" 2>/dev/null | cut -d= -f2
}

egress_region() {
  python3 -c "import json; print(json.load(open('$PSIPHON_CONFIG')).get('EgressRegion', '?'))" 2>/dev/null || echo "?"
}

google_route() {
  # config.json just says "google-out" now — ask the Clash API what
  # it's actually pointing at.
  curl -fsS http://127.0.0.1:9090/proxies/google-out 2>/dev/null \
    | python3 -c "import json, sys; print(json.load(sys.stdin)['now'])" 2>/dev/null || echo "?"
}

psiphon_wait_up() {
  local port="$1"
  for _ in $(seq 1 12); do
    code="$(curl -s -o /dev/null --max-time 10 --socks5-hostname "127.0.0.1:${port}" \
            -w '%{http_code}' https://www.gstatic.com/generate_204 2>/dev/null)"
    [ "$code" = "204" ] && return 0
    sleep 5
  done
  return 1
}

psiphon_verdict() {
  # Same signals psiphon-watchdog.sh itself checks, so this shows the
  # truth about what would (or wouldn't) trigger a rotation.
  local port="$1"
  local ads_loc ads_cc sr bcode bgot bfirst btotal kbps

  ads_loc="$(curl -s -o /dev/null --max-time 15 --socks5-hostname "127.0.0.1:${port}" \
             -w '%{redirect_url}' https://ads.google.com/home/ 2>/dev/null || true)"
  ads_cc="$(echo "$ads_loc" | grep -oE 'business\.google\.com/[a-z]{2}/' \
            | sed -E 's#business\.google\.com/([a-z]{2})/#\1#' | tr '[:lower:]' '[:upper:]')"
  sr="$(grep -oE '"serverRegion":"[A-Z]{2}"' /var/log/psiphon/notices.log 2>/dev/null | tail -1 | cut -d'"' -f4)"

  read -r bcode bgot bfirst btotal <<<"$(curl -s -o /dev/null --max-time 25 --socks5-hostname "127.0.0.1:${port}" \
    -r "0-4194303" -w '%{http_code} %{size_download} %{time_starttransfer} %{time_total}' \
    https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb 2>/dev/null)"
  case "${bcode:-000}" in
    200|206) kbps="$(awk -v s="${bgot:-0}" -v f="${bfirst:-0}" -v t="${btotal:-0}" \
               'BEGIN { d = t - f; print ((d > 0 && s > 0) ? int(s / d / 1024) : 0) }')" ;;
    *) kbps="?" ;;
  esac

  echo "  Throughput: ${kbps} KB/s"
  echo "  Google verdict (ads.google.com): ${ads_cc:-?}"
  echo "  Psiphon's own server region: ${sr:-?}"
  if [ -n "$sr" ] && [ -n "$ads_cc" ] && [ "$sr" != "$ads_cc" ]; then
    echo "  -> mismatch, the watchdog would rotate on this"
  fi
}

psiphon_status() {
  local port; port="$(socks_port)"
  echo "=== Psiphon ==="
  echo "Requested region (psiphon.config): $(egress_region)"
  echo "Service active: $(systemctl is-active psiphon 2>/dev/null)"
  echo "Google traffic currently routed via: $(google_route)"
  echo
  echo "Current verdict (live check):"
  psiphon_verdict "$port"
}

psiphon_restart_same_region() {
  local port; port="$(socks_port)"
  echo "Restarting psiphon (same region, fresh exit IP)..."
  systemctl restart psiphon
  if psiphon_wait_up "$port"; then
    echo "Tunnel is up. New verdict:"
    psiphon_verdict "$port"
  else
    echo "ERROR: tunnel did not come up within 60s, check journalctl -u psiphon"
  fi
}

psiphon_rotate_region() {
  local port; port="$(socks_port)"
  moved="$(/usr/local/sbin/psiphon-advance-region 2>/dev/null)"
  if [ -z "$moved" ]; then
    echo "REGION_POOL is empty or only has one region — no rotation to do."
    return
  fi
  echo "Region: $moved"
  systemctl restart psiphon
  if psiphon_wait_up "$port"; then
    echo "Tunnel is up. New verdict:"
    psiphon_verdict "$port"
  else
    echo "ERROR: tunnel did not come up within 60s, check journalctl -u psiphon"
  fi
}

# =========================================================================
# Services
# =========================================================================

services_status() {
  local svc
  for svc in nginx caddy-naive sing-box wdtt psiphon psiphon-watchdog.timer ufw fail2ban; do
    if [ "$svc" = "wdtt" ] && ! systemctl is-enabled --quiet wdtt 2>/dev/null; then
      echo "  ${C_YELLOW}--${C_RESET}   wdtt (no qWDTT clients yet)"
      continue
    fi
    if systemctl is-active --quiet "$svc"; then
      echo "  ${C_GREEN}OK${C_RESET}   $svc"
    else
      echo "  ${C_RED}FAIL${C_RESET} $svc"
    fi
  done
}

# =========================================================================
# Binary updates — the same safe patterns bootstrap.sh uses (stop before
# swap, backup + restore on failure), but scoped to just these four
# binaries: no firewall/fail2ban/nginx/Caddyfile changes, and none of
# bootstrap.sh's required env vars to remember.
# =========================================================================

# qWDTT/Psiphon have no version command for bootstrap.sh to compare
# against VERSIONS, so updating one here marks it overridden — a later
# bootstrap.sh run leaves it alone instead of reverting to the pin.
mark_overridden() {
  local f="/var/lib/vps-bootstrap/overrides"
  mkdir -p "$(dirname "$f")"
  touch "$f"
  grep -qx "$1" "$f" || echo "$1" >> "$f"
}

update_singbox() {
  echo "Updating sing-box..."
  bash <(curl -fsSL https://sing-box.app/install.sh) >/dev/null
  if ! sing-box check -c "$SING_BOX_CONFIG"; then
    echo "ERROR: the new sing-box binary fails to validate the existing config — not restarting the service."
    return 1
  fi
  systemctl restart sing-box
  sleep 1
  if systemctl is-active --quiet sing-box; then
    echo "sing-box updated: $(sing-box version | head -1)"
  else
    echo "ERROR: sing-box did not come back up, check journalctl -u sing-box"
    return 1
  fi
}

update_caddy() {
  echo "Updating Caddy..."
  local url tmp_extract
  url="$(curl -s https://api.github.com/repos/caddyserver/caddy/releases/latest \
    | grep browser_download_url | grep "linux_amd64.tar.gz\"" | cut -d '"' -f4)"
  [ -z "$url" ] && { echo "ERROR: could not find the latest Caddy release"; return 1; }

  cp /usr/local/bin/caddy /usr/local/bin/caddy.bak
  curl -fsSL -o /tmp/caddy.tar.gz "$url"
  tmp_extract="$(mktemp -d)"
  tar xzf /tmp/caddy.tar.gz -C "$tmp_extract"
  rm -f /tmp/caddy.tar.gz

  systemctl stop caddy-naive
  mv "$tmp_extract/caddy" /usr/local/bin/caddy
  chmod +x /usr/local/bin/caddy
  rm -rf "$tmp_extract"

  if ! caddy validate --config "$CADDYFILE" --adapter caddyfile; then
    echo "ERROR: the new Caddy binary rejects the existing Caddyfile — restoring the previous binary."
    mv /usr/local/bin/caddy.bak /usr/local/bin/caddy
    systemctl start caddy-naive
    return 1
  fi
  systemctl start caddy-naive
  sleep 1
  if systemctl is-active --quiet caddy-naive; then
    rm -f /usr/local/bin/caddy.bak
    echo "Caddy updated: $(caddy version)"
  else
    echo "ERROR: caddy-naive did not come back up, check journalctl -u caddy-naive"
    return 1
  fi
}

update_qwdtt() {
  echo "Updating qWDTT..."
  export PATH=/usr/local/go/bin:$PATH
  if ! command -v go >/dev/null 2>&1; then
    curl -fsSL https://go.dev/dl/go1.26.6.linux-amd64.tar.gz -o /tmp/go.tar.gz
    rm -rf /usr/local/go
    tar -C /usr/local -xzf /tmp/go.tar.gz
    rm -f /tmp/go.tar.gz
    export PATH=/usr/local/go/bin:$PATH
  fi

  # Throwaway clone, not kept — the repo's Android app isn't needed.
  local src; src="$(mktemp -d)"
  git init -q "$src"
  git -C "$src" remote add origin https://github.com/SpaceNeuroX/proxy-turn-vk-android.git
  # "origin HEAD" always resolves to the remote's real default branch.
  git -C "$src" fetch --depth 1 origin HEAD
  git -C "$src" checkout --detach FETCH_HEAD

  local was_enabled=0
  systemctl is-enabled --quiet wdtt 2>/dev/null && was_enabled=1

  cp /usr/local/bin/wdtt-server /usr/local/bin/wdtt-server.bak
  systemctl stop wdtt
  if ! (cd "$src" && go build -o /usr/local/bin/wdtt-server ./server); then
    echo "ERROR: build failed — restoring the previous binary."
    mv /usr/local/bin/wdtt-server.bak /usr/local/bin/wdtt-server
    [ "$was_enabled" = 1 ] && systemctl start wdtt
    rm -rf "$src"
    return 1
  fi
  chmod 755 /usr/local/bin/wdtt-server
  rm -rf "$src"

  # No qWDTT clients at all: nothing to actually run, so nothing to
  # verify either — the new binary is in place and that's the update.
  if [ "$was_enabled" = 0 ]; then
    rm -f /usr/local/bin/wdtt-server.bak
    mark_overridden qwdtt
    echo "qWDTT updated (no clients yet, so nothing is running to restart)."
    return 0
  fi

  systemctl start wdtt
  sleep 1
  if systemctl is-active --quiet wdtt; then
    rm -f /usr/local/bin/wdtt-server.bak
    mark_overridden qwdtt
    echo "qWDTT updated and running."
  else
    echo "ERROR: wdtt did not come back up — restoring the previous binary."
    systemctl stop wdtt
    mv /usr/local/bin/wdtt-server.bak /usr/local/bin/wdtt-server
    systemctl start wdtt
    return 1
  fi
}

update_psiphon() {
  echo "Updating Psiphon..."
  local port; port="$(socks_port)"
  cp /usr/local/bin/psiphon-tunnel-core /usr/local/bin/psiphon-tunnel-core.bak
  curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 -o /tmp/psiphon-tunnel-core.new \
    "https://raw.githubusercontent.com/Psiphon-Labs/psiphon-tunnel-core-binaries/master/linux/psiphon-tunnel-core-x86_64"
  chmod 755 /tmp/psiphon-tunnel-core.new
  mv /tmp/psiphon-tunnel-core.new /usr/local/bin/psiphon-tunnel-core

  systemctl restart psiphon
  if psiphon_wait_up "$port"; then
    rm -f /usr/local/bin/psiphon-tunnel-core.bak
    mark_overridden psiphon
    echo "Psiphon updated and tunnel is up."
  else
    echo "ERROR: the new Psiphon binary did not come up — restoring the previous one."
    mv /usr/local/bin/psiphon-tunnel-core.bak /usr/local/bin/psiphon-tunnel-core
    systemctl restart psiphon
    return 1
  fi
}

update_all_binaries() {
  echo "This updates sing-box, Caddy, qWDTT and Psiphon to their latest versions."
  echo "It does NOT touch firewall/fail2ban/nginx — those stay as they are."
  local ans; ans=$(ask_yn "Continue? [y/N]" N)
  [ "$ans" = 1 ] || { echo "Cancelled."; return; }

  local failed=()
  update_singbox || failed+=("sing-box")
  echo
  update_caddy || failed+=("Caddy")
  echo
  update_qwdtt || failed+=("qWDTT")
  echo
  update_psiphon || failed+=("Psiphon")

  echo
  if [ "${#failed[@]}" = 0 ]; then
    echo "All updated successfully."
  else
    echo "Failed: ${failed[*]} — see the errors above."
  fi
}

# =========================================================================
# Menu
# =========================================================================

while true; do
  echo
  echo "${C_BOLD}${C_CYAN}=== Server management ($(domain)) — version $(deployed_version) ===${C_RESET}"
  echo "${C_CYAN}Clients:${C_RESET}"
  echo "  1) List clients"
  echo "  2) Add client"
  echo "  3) Remove client"
  echo "  4) Show client config (vless link + JSON)"
  echo "  5) Toggle Google/YouTube direct routing for a client"
  echo "${C_CYAN}Psiphon:${C_RESET}"
  echo "  6) Status (region / Google verdict / speed)"
  echo "  7) Change exit IP (same region)"
  echo "  8) Change region (next in the pool)"
  echo "${C_CYAN}Services:${C_RESET}"
  echo "  9) Status of all services"
  echo "  10) Update sing-box/Caddy/qWDTT/Psiphon to latest"
  echo "  0) Exit"
  read -rp "> " choice
  case "$choice" in
    1) list_clients ;;
    2) add_client ;;
    3) remove_client ;;
    4) show_client_config ;;
    5) toggle_direct_route ;;
    6) psiphon_status ;;
    7) psiphon_restart_same_region ;;
    8) psiphon_rotate_region ;;
    9) services_status ;;
    10) update_all_binaries ;;
    0) exit 0 ;;
    *) echo "Unrecognized choice, pick an item from the list." ;;
  esac
done
