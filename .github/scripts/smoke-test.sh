#!/usr/bin/env bash
# Runs after bootstrap.sh on a CI runner, as root. Builds real client
# configs from the secrets bootstrap.sh just generated and connects
# through the server over loopback — same binary, same protocols, same
# host, just no real domain/cert involved (see SKIP_CERTBOT in
# bootstrap.sh). Confirms the two main client paths actually carry
# traffic end to end, not just that the services report "active".
set -euo pipefail

DOMAIN="${DOMAIN:?set DOMAIN}"
CLIENT_NAME="${CLIENT_NAME:?set CLIENT_NAME}"
SECRETS_FILE=/root/.vps-bootstrap-secrets.env
WORKDIR="$(mktemp -d)"
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$WORKDIR"' EXIT

fail=0
ok()   { printf '  OK   %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*"; fail=1; }
warn() { printf '  WARN %s\n' "$*"; }

python3 - "$DOMAIN" "$CLIENT_NAME" "$SECRETS_FILE" "$WORKDIR" <<'PYEOF'
import json, sys

domain, client_name, secrets_file, workdir = sys.argv[1:5]
env = {}
with open(secrets_file) as f:
    for line in f:
        line = line.strip()
        if not line or "=" not in line:
            continue
        k, v = line.split("=", 1)
        env[k] = v

reality_client = {
    "inbounds": [{"type": "socks", "tag": "in", "listen": "127.0.0.1", "listen_port": 19001}],
    "outbounds": [{
        "type": "vless", "tag": "out", "server": "127.0.0.1", "server_port": 443,
        "uuid": env[f"CLIENT_{client_name}_UUID"], "flow": "xtls-rprx-vision",
        "tls": {
            "enabled": True, "server_name": domain,
            "utls": {"enabled": True, "fingerprint": "chrome"},
            "reality": {
                "enabled": True,
                "public_key": env["REALITY_PUBLIC_KEY"],
                "short_id": env["SHORT_ID"],
            },
        },
    }],
    "route": {"final": "out"},
}

naive_client = {
    "inbounds": [{"type": "socks", "tag": "in", "listen": "127.0.0.1", "listen_port": 19002}],
    "outbounds": [{
        "type": "naive", "tag": "out", "server": "127.0.0.1", "server_port": 443,
        "username": client_name, "password": env[f"CLIENT_{client_name}_NAIVE_PASS"],
        # insecure: CI's cert is self-signed (SKIP_CERTBOT=1), a real
        # deployment has a real Let's Encrypt cert and never sets this.
        "tls": {"enabled": True, "server_name": domain, "insecure": True},
    }],
    "route": {"final": "out"},
}

json.dump(reality_client, open(f"{workdir}/reality-client.json", "w"))
json.dump(naive_client, open(f"{workdir}/naive-client.json", "w"))
PYEOF

echo "--- Reality/VLESS: client -> 127.0.0.1:443 -> psiphon-out -> gstatic ---"
sing-box run -c "$WORKDIR/reality-client.json" > "$WORKDIR/reality-client.log" 2>&1 &
sleep 2
code="$(curl -x socks5h://127.0.0.1:19001 -sS -o /dev/null -w '%{http_code}' --max-time 15 https://www.gstatic.com/generate_204 || echo "000")"
if [ "$code" = "204" ]; then ok "Reality proxy reached gstatic (HTTP $code)"; else bad "Reality proxy did not work (HTTP $code) — see $WORKDIR/reality-client.log"; cat "$WORKDIR/reality-client.log"; fi
kill %1 2>/dev/null || true
wait 2>/dev/null || true

echo "--- naive: client -> Caddy:8446 (via Reality fallback on :443) -> naive-in -> gstatic ---"
sing-box run -c "$WORKDIR/naive-client.json" > "$WORKDIR/naive-client.log" 2>&1 &
sleep 2
code="$(curl -x socks5h://127.0.0.1:19002 -sS -o /dev/null -w '%{http_code}' --max-time 15 https://www.gstatic.com/generate_204 || echo "000")"
if [ "$code" = "204" ]; then ok "naive proxy reached gstatic (HTTP $code)"; else bad "naive proxy did not work (HTTP $code) — see $WORKDIR/naive-client.log"; cat "$WORKDIR/naive-client.log"; fi
kill %1 2>/dev/null || true
wait 2>/dev/null || true

echo "--- qWDTT: DTLS port listening ---"
if ss -lun | grep -q ":${WDTT_DTLS_PORT:-48219}\s"; then ok "qWDTT listening on UDP ${WDTT_DTLS_PORT:-48219}"; else bad "qWDTT not listening on UDP ${WDTT_DTLS_PORT:-48219}"; fi

echo "--- Psiphon: local SOCKS port + real tunnel connection ---"
if ss -ln | grep -q ":11080\s"; then ok "Psiphon SOCKS listening on 11080"; else bad "Psiphon SOCKS not listening on 11080"; fi

region=""
for _ in $(seq 1 30); do
  region="$(grep -oE '"serverRegion":"[A-Z]{2}"' /var/log/psiphon/notices.log 2>/dev/null | tail -1 | cut -d'"' -f4)"
  [ -n "$region" ] && break
  sleep 3
done
if [ -n "$region" ]; then
  ok "Psiphon connected, serverRegion=$region"
else
  # Depends on Psiphon's real network being reachable from this runner —
  # outside our control, so this doesn't fail the build, just flags it.
  warn "Psiphon did not report a connected server within 90s (shared-IP network flakiness, not necessarily a real regression)"
fi

exit "$fail"
