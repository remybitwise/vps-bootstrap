#!/usr/bin/env bash
# manage.sh — self-contained interactive server-management menu: clients
# (Reality/naive/qWDTT, each addable/removable independently), Psiphon
# (status/change exit IP/change region), service status/restart.
#
# Self-contained on purpose: everything needed lives in this one file, no
# sibling scripts required. The one external dependency kept is
# /usr/local/sbin/psiphon-advance-region — that's a core part of the
# already-deployed Psiphon watchdog subsystem (psiphon-watchdog.sh itself
# depends on it too), not a convenience script of this toolset, so it's
# not duplicated here.
#
# Deliberately no `set -e` at the top level — this is an interactive loop,
# one failed operation should not kill the whole menu. Each client
# operation below runs in a `(set -e; ...)` subshell instead, so it aborts
# cleanly on its own first error without taking the menu down with it.

SECRETS_FILE="/root/.vps-bootstrap-secrets.env"
SING_BOX_CONFIG=/etc/sing-box/config.json
CADDYFILE=/etc/caddy/Caddyfile
WDTT_CONFIG=/etc/wdtt/passwords.json
WDTT_SERVICE=/etc/systemd/system/wdtt.service
PSIPHON_DEFAULT=/etc/default/psiphon-watchdog
PSIPHON_CONFIG=/etc/psiphon/psiphon.config
WATCHDOG_LOG=/var/log/psiphon/watchdog.log

[ "$(id -u)" = "0" ] || { echo "ERROR: run as root"; exit 1; }

domain() {
  python3 -c "import json; print(json.load(open('$SING_BOX_CONFIG'))['inbounds'][0]['tls']['server_name'])" 2>/dev/null || echo "?"
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
for name in sorted(reality | naive):
    tags = []
    if name in reality: tags.append('reality')
    if name in naive: tags.append('naive')
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
import base64, json, sys

domain, config_path, caddyfile_path = sys.argv[1:4]
d = json.load(open(config_path))
naive_users = next(i["users"] for i in d["inbounds"] if i["tag"] == "naive-in")

b64_headers = [
    base64.b64encode(f"{u['username']}:{u['password']}".encode()).decode()
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
    if do_naive == "1" and i["tag"] == "naive-in":
        i["users"].append({"username": name, "password": naive_pass})
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

  systemctl start wdtt
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
  systemctl start wdtt
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

# =========================================================================
# Psiphon
# =========================================================================

socks_port() {
  grep -oE '^SOCKS_PORT=[0-9]+' "$PSIPHON_DEFAULT" 2>/dev/null | cut -d= -f2
}

egress_region() {
  python3 -c "import json; print(json.load(open('$PSIPHON_CONFIG')).get('EgressRegion', '?'))" 2>/dev/null || echo "?"
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

watchdog_log_tail() {
  tail -25 "$WATCHDOG_LOG" 2>/dev/null || echo "(log file not found)"
}

# =========================================================================
# Services
# =========================================================================

services_status() {
  local svc
  for svc in nginx caddy-naive sing-box wdtt psiphon psiphon-watchdog.timer ufw fail2ban; do
    if systemctl is-active --quiet "$svc"; then
      echo "  OK   $svc"
    else
      echo "  FAIL $svc"
    fi
  done
}

restart_one_service() {
  echo "Which service to restart?"
  echo "  1) sing-box"
  echo "  2) caddy-naive"
  echo "  3) wdtt"
  echo "  4) cancel"
  read -rp "> " c
  case "$c" in
    1) systemctl restart sing-box && echo "sing-box restarted." ;;
    2) systemctl restart caddy-naive && echo "caddy-naive restarted." ;;
    3) systemctl restart wdtt && echo "wdtt restarted." ;;
    *) echo "Cancelled." ;;
  esac
}

# =========================================================================
# Menu
# =========================================================================

while true; do
  echo
  echo "=== Server management ($(domain)) ==="
  echo "Clients:"
  echo "  1) List clients"
  echo "  2) Add client"
  echo "  3) Remove client"
  echo "Psiphon:"
  echo "  4) Status (region / Google verdict / speed)"
  echo "  5) Change exit IP (same region)"
  echo "  6) Change region (next in the pool)"
  echo "  7) Tail watchdog log"
  echo "Services:"
  echo "  8) Status of all services"
  echo "  9) Restart sing-box/caddy-naive/wdtt"
  echo "  0) Exit"
  read -rp "> " choice
  case "$choice" in
    1) list_clients ;;
    2) add_client ;;
    3) remove_client ;;
    4) psiphon_status ;;
    5) psiphon_restart_same_region ;;
    6) psiphon_rotate_region ;;
    7) watchdog_log_tail ;;
    8) services_status ;;
    9) restart_one_service ;;
    0) exit 0 ;;
    *) echo "Unrecognized choice, pick an item from the list." ;;
  esac
done
