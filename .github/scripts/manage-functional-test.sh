#!/usr/bin/env bash
# Runs after smoke-test.sh, as root. Drives manage.sh exactly the way a
# person at the menu would (piped stdin, same prompts), then checks the
# actual state it's supposed to produce: secrets, sing-box/wdtt configs,
# and a real client connection for the client it just added.
set -uo pipefail

DOMAIN="${DOMAIN:?set DOMAIN}"
CLIENT_NAME="${CLIENT_NAME:?set CLIENT_NAME}"
FAIL=0
NEW_CLIENT="${NEW_CLIENT:-citest2}"
SECRETS_FILE=/root/.vps-bootstrap-secrets.env
SING_BOX_CONFIG=/etc/sing-box/config.json
WDTT_CONFIG=/etc/wdtt/passwords.json

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

run_manage() { printf '%b' "$1" | bash manage.sh; }

echo "--- manage.sh: add client '$NEW_CLIENT' (Reality + naive + qWDTT) ---"
out="$(run_manage "2\n${NEW_CLIENT}\nY\nY\nY\n0\n" 2>&1)"
echo "$out"

repo_version="$(cat VERSION)"
echo "$out" | grep -q "version $repo_version" && ok "menu header shows the deployed version ($repo_version)" || bad "menu header does not show version $repo_version"

if grep -q "^CLIENT_${NEW_CLIENT}_UUID=" "$SECRETS_FILE"; then ok "secrets: Reality UUID written"; else bad "secrets: Reality UUID missing"; fi
if grep -q "^CLIENT_${NEW_CLIENT}_NAIVE_PASS=" "$SECRETS_FILE"; then ok "secrets: naive password written"; else bad "secrets: naive password missing"; fi

python3 -c "
import json, sys
d = json.load(open('$SING_BOX_CONFIG'))
reality = {u['name'] for i in d['inbounds'] if i['tag']=='vless-reality-in' for u in i['users']}
naive = {u['username'] for i in d['inbounds'] if i['tag']=='naive-in' for u in i['users']}
sys.exit(0 if ('$NEW_CLIENT' in reality and '$NEW_CLIENT' in naive) else 1)
" && ok "sing-box config: '$NEW_CLIENT' listed under Reality and naive" || bad "sing-box config: '$NEW_CLIENT' missing from Reality/naive"

python3 -c "
import json, sys
d = json.load(open('$WDTT_CONFIG'))
sys.exit(0 if any(v.get('label') == '$NEW_CLIENT' for v in d['passwords'].values()) else 1)
" && ok "qWDTT: '$NEW_CLIENT' listed in passwords.json" || bad "qWDTT: '$NEW_CLIENT' missing from passwords.json"

systemctl is-active --quiet sing-box && ok "sing-box still active after add" || bad "sing-box not active after add"
systemctl is-active --quiet wdtt && ok "wdtt still active after add" || bad "wdtt not active after add"

echo "--- real connection check for the newly added client ---"
test_client "$DOMAIN" "$NEW_CLIENT" || true

echo "--- manage.sh: toggle Google/YouTube direct routing for '$NEW_CLIENT' ---"
out="$(run_manage "5\n${NEW_CLIENT}\n1\n0\n" 2>&1)"
echo "$out"
echo "$out" | grep -q "always direct" && ok "menu: direct routing toggled on" || bad "menu: direct routing toggle-on did not report success"
echo "$out" | grep -qE "^\s*${NEW_CLIENT}:.*google-direct" && ok "menu: list_clients shows google-direct tag" || bad "menu: list_clients missing google-direct tag"
grep -q "^CLIENT_${NEW_CLIENT}_ROUTE=direct$" "$SECRETS_FILE" && ok "secrets: direct-route flag written" || bad "secrets: direct-route flag missing"

out="$(run_manage "5\n${NEW_CLIENT}\n1\n0\n" 2>&1)"
echo "$out"
echo "$out" | grep -q "normal Psiphon switch" && ok "menu: direct routing toggled off" || bad "menu: direct routing toggle-off did not report success"
echo "$out" | grep -qE "^\s*${NEW_CLIENT}:.*google-direct" && bad "menu: list_clients still shows google-direct tag after toggle-off" || ok "menu: list_clients no longer shows google-direct tag"
grep -q "^CLIENT_${NEW_CLIENT}_ROUTE=direct$" "$SECRETS_FILE" && bad "secrets: direct-route flag still present after toggle-off" || ok "secrets: direct-route flag gone"

systemctl is-active --quiet sing-box && ok "sing-box still active after routing toggle" || bad "sing-box not active after routing toggle"

echo "--- manage.sh: remove client '$NEW_CLIENT' (Reality + naive + qWDTT) ---"
out="$(run_manage "3\n${NEW_CLIENT}\nY\nY\nY\n0\n" 2>&1)"
echo "$out"

if grep -q "^CLIENT_${NEW_CLIENT}_UUID=" "$SECRETS_FILE"; then bad "secrets: Reality UUID still present after remove"; else ok "secrets: Reality UUID gone"; fi
if grep -q "^CLIENT_${NEW_CLIENT}_NAIVE_PASS=" "$SECRETS_FILE"; then bad "secrets: naive password still present after remove"; else ok "secrets: naive password gone"; fi

python3 -c "
import json, sys
d = json.load(open('$SING_BOX_CONFIG'))
reality = {u['name'] for i in d['inbounds'] if i['tag']=='vless-reality-in' for u in i['users']}
naive = {u['username'] for i in d['inbounds'] if i['tag']=='naive-in' for u in i['users']}
sys.exit(1 if ('$NEW_CLIENT' in reality or '$NEW_CLIENT' in naive) else 0)
" && ok "sing-box config: '$NEW_CLIENT' gone from Reality and naive" || bad "sing-box config: '$NEW_CLIENT' still listed"

python3 -c "
import json, sys
d = json.load(open('$WDTT_CONFIG'))
sys.exit(1 if any(v.get('label') == '$NEW_CLIENT' for v in d['passwords'].values()) else 0)
" && ok "qWDTT: '$NEW_CLIENT' gone from passwords.json" || bad "qWDTT: '$NEW_CLIENT' still listed"

echo "--- manage.sh: Psiphon status / show client config / services status via menu ---"
out="$(run_manage "6\n4\n${CLIENT_NAME}\n9\n0\n" 2>&1)"
echo "$out"

echo "$out" | grep -q "=== Psiphon ===" && ok "menu: Psiphon status ran" || bad "menu: Psiphon status did not print"
echo "$out" | grep -q "vless://" && ok "menu: show client config printed a vless link" || bad "menu: show client config did not print a vless link"
echo "$out" | grep -q '"type": "vless"' && ok "menu: show client config printed Reality JSON" || bad "menu: show client config did not print Reality JSON"
echo "$out" | grep -q "wdtt://" && ok "menu: show client config printed a wdtt link" || bad "menu: show client config did not print a wdtt link"
echo "$out" | grep -q "qwdtt://config" && ok "menu: show client config printed a qwdtt link" || bad "menu: show client config did not print a qwdtt link"
# $out is scoped to just this one menu run (6, 4, CLIENT_NAME, 9, 0) —
# services_status is the only thing in it that ever prints the word FAIL.
if echo "$out" | grep -q "FAIL"; then bad "menu: services_status reported a FAIL"; else ok "menu: services_status reported no FAIL"; fi

echo "--- manage.sh: update sing-box/Caddy/qWDTT/Psiphon (option 10) ---"
out="$(run_manage "10\nY\n0\n" 2>&1)"
echo "$out"

echo "$out" | grep -q "sing-box updated:" && ok "menu: sing-box update reported success" || bad "menu: sing-box update did not report success"
echo "$out" | grep -q "Caddy updated:" && ok "menu: Caddy update reported success" || bad "menu: Caddy update did not report success"
echo "$out" | grep -q "qWDTT updated and running\." && ok "menu: qWDTT update reported success" || bad "menu: qWDTT update did not report success"
echo "$out" | grep -q "Psiphon updated and tunnel is up\." && ok "menu: Psiphon update reported success" || bad "menu: Psiphon update did not report success"
echo "$out" | grep -q "All updated successfully\." && ok "menu: update summary reported success" || bad "menu: update summary did not report success"

for svc in sing-box caddy-naive wdtt psiphon; do
  systemctl is-active --quiet "$svc" && ok "$svc active after binary update" || bad "$svc not active after binary update"
done

echo "--- real connection check after the binary update ---"
test_client "$DOMAIN" "$CLIENT_NAME" || true

exit "$FAIL"
