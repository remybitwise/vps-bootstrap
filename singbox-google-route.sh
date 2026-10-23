#!/usr/bin/env bash
# singbox-google-route.sh direct|psiphon — flips the google-out selector
# between the Psiphon outbound and this VPS's own IP, via sing-box's
# Clash API (127.0.0.1:9090). Called by psiphon-watchdog.sh; safe to run
# by hand too.
set -euo pipefail

API=http://127.0.0.1:9090
target="${1:?usage: singbox-google-route.sh direct|psiphon}"

case "$target" in
  direct) new_outbound=direct ;;
  psiphon) new_outbound=psiphon-out ;;
  *) echo "ERROR: argument must be 'direct' or 'psiphon'" >&2; exit 1 ;;
esac

if ! current_raw="$(curl -fsS "$API/proxies/google-out")"; then
  echo "ERROR: could not reach sing-box's Clash API at $API — is sing-box running?" >&2
  exit 1
fi
current="$(printf '%s' "$current_raw" | python3 -c "import json, sys; print(json.load(sys.stdin)['now'])")"

if [ "$current" = "$new_outbound" ]; then
  echo "Google route already: $target (no change)"
  exit 0
fi

if ! code="$(curl -s -o /dev/null -w '%{http_code}' -X PUT "$API/proxies/google-out" \
        -H 'Content-Type: application/json' -d "{\"name\":\"$new_outbound\"}")"; then
  echo "ERROR: could not reach sing-box's Clash API at $API — is sing-box running?" >&2
  exit 1
fi
if [ "$code" != "204" ]; then
  echo "ERROR: Clash API PUT failed (HTTP $code)" >&2
  exit 1
fi
echo "Google route switched to: $target"
