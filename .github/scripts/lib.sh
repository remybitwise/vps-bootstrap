#!/usr/bin/env bash
# Shared by smoke-test.sh and manage-functional-test.sh. Not meant to be
# run directly — sourced for its ok/bad/warn helpers and test_client().

ok()   { printf '  OK   %s\n' "$*"; }
# shellcheck disable=SC2034
bad()  { printf '  FAIL %s\n' "$*"; FAIL=1; }  # FAIL is read by the sourcing script
warn() { printf '  WARN %s\n' "$*"; }

# test_client <domain> <client_name> — builds real Reality/naive client
# configs from whatever secrets currently exist for that name and connects
# through the server over loopback. Skips a protocol entirely if the name
# has no secret for it (e.g. naive-only clients), so it works right after
# manage.sh adds or removes either side independently.
test_client() {
  local domain="$1" name="$2"
  local secrets_file=/root/.vps-bootstrap-secrets.env
  local workdir; workdir="$(mktemp -d)"
  local result=0

  python3 - "$domain" "$name" "$secrets_file" "$workdir" <<'PYEOF'
import json, sys
domain, name, secrets_file, workdir = sys.argv[1:5]
env = {}
with open(secrets_file) as f:
    for line in f:
        line = line.strip()
        if not line or "=" not in line:
            continue
        k, v = line.split("=", 1)
        env[k] = v

if f"CLIENT_{name}_UUID" in env:
    reality_client = {
        "inbounds": [{"type": "socks", "tag": "in", "listen": "127.0.0.1", "listen_port": 19001}],
        "outbounds": [{
            "type": "vless", "tag": "out", "server": "127.0.0.1", "server_port": 443,
            "uuid": env[f"CLIENT_{name}_UUID"], "flow": "xtls-rprx-vision",
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
    json.dump(reality_client, open(f"{workdir}/reality-client.json", "w"))

if f"CLIENT_{name}_NAIVE_PASS" in env:
    naive_client = {
        "inbounds": [{"type": "socks", "tag": "in", "listen": "127.0.0.1", "listen_port": 19002}],
        "outbounds": [{
            "type": "naive", "tag": "out", "server": "127.0.0.1", "server_port": 443,
            "username": name, "password": env[f"CLIENT_{name}_NAIVE_PASS"],
            # self-signed CI cert (SKIP_CERTBOT=1) trusted explicitly —
            # naive's TLS stack rejects the generic "insecure" flag, and a
            # real deployment has a real cert and never sets this.
            "tls": {
                "enabled": True, "server_name": domain,
                "certificate_path": f"/etc/letsencrypt/live/{domain}/fullchain.pem",
            },
        }],
        "route": {"final": "out"},
    }
    json.dump(naive_client, open(f"{workdir}/naive-client.json", "w"))
PYEOF

  if [ -f "$workdir/reality-client.json" ]; then
    sing-box run -c "$workdir/reality-client.json" > "$workdir/reality.log" 2>&1 &
    local pid=$!
    sleep 2
    local code
    # retries: a lone SSL_ERROR_SYSCALL on the real hop to gstatic is a
    # transient CI-network blip, not a regression — seen it self-resolve
    # on every manual retry so far.
    for _ in 1 2 3; do
      code="$(curl -x socks5h://127.0.0.1:19001 -sS -o /dev/null -w '%{http_code}' --max-time 15 https://www.gstatic.com/generate_204 || echo 000)"
      [ "$code" = "204" ] && break
      sleep 2
    done
    kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
    if [ "$code" = "204" ]; then
      ok "[$name] Reality reached gstatic (HTTP $code)"
    else
      bad "[$name] Reality did not work (HTTP $code)"; cat "$workdir/reality.log"; result=1
    fi
  fi

  if [ -f "$workdir/naive-client.json" ]; then
    sing-box run -c "$workdir/naive-client.json" > "$workdir/naive.log" 2>&1 &
    local pid=$!
    sleep 2
    local code
    for _ in 1 2 3; do
      code="$(curl -x socks5h://127.0.0.1:19002 -sS -o /dev/null -w '%{http_code}' --max-time 15 https://www.gstatic.com/generate_204 || echo 000)"
      [ "$code" = "204" ] && break
      sleep 2
    done
    kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
    if [ "$code" = "204" ]; then
      ok "[$name] naive reached gstatic (HTTP $code)"
    else
      bad "[$name] naive did not work (HTTP $code)"; cat "$workdir/naive.log"; result=1
    fi
  fi

  if [ ! -f "$workdir/reality-client.json" ] && [ ! -f "$workdir/naive-client.json" ]; then
    bad "[$name] no Reality or naive secret found for this name — nothing was actually tested"
    result=1
  fi

  rm -rf "$workdir"
  return $result
}
