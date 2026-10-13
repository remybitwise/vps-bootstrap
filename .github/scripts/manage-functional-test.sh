#!/usr/bin/env bash
# Runs after smoke-test.sh, as root. Drives manage.sh exactly the way a
# person at the menu would (piped stdin, same prompts), then checks the
# actual state it's supposed to produce: secrets, sing-box/wdtt configs,
# and a real client connection for the client it just added.
set -uo pipefail

DOMAIN="${DOMAIN:?set DOMAIN}"
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

echo "--- manage.sh: Psiphon status / services status / restart via menu ---"
out="$(run_manage "4\n8\n9\n1\n0\n" 2>&1)"
echo "$out"

echo "$out" | grep -q "=== Psiphon ===" && ok "menu: Psiphon status ran" || bad "menu: Psiphon status did not print"
echo "$out" | grep -q "sing-box restarted\." && ok "menu: sing-box restart via menu ran" || bad "menu: sing-box restart did not print confirmation"
if echo "$out" | grep -A20 "Status of all services" | grep -q "FAIL"; then bad "menu: services_status reported a FAIL"; else ok "menu: services_status reported no FAIL"; fi
systemctl is-active --quiet sing-box && ok "sing-box active after menu restart" || bad "sing-box not active after menu restart"

exit "$FAIL"
