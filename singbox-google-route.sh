#!/usr/bin/env bash
# singbox-google-route.sh direct|psiphon — flips where sing-box sends
# Google-destined traffic (the route.rules entry matching the
# google-geosite/google-geoip rule_sets) between the Psiphon outbound and
# this VPS's own IP. Idempotent and quiet: restarts sing-box only if the
# value actually changes, since restarting it interrupts every client
# (Reality/naive/qWDTT), not just the Google path. Called by
# psiphon-watchdog.sh; safe to run by hand too.
set -euo pipefail

CONFIG=/etc/sing-box/config.json
target="${1:?usage: singbox-google-route.sh direct|psiphon}"

case "$target" in
  direct) new_outbound=direct ;;
  psiphon) new_outbound=psiphon-out ;;
  *) echo "ERROR: argument must be 'direct' or 'psiphon'" >&2; exit 1 ;;
esac

changed="$(python3 -c "
import json
p = '$CONFIG'
d = json.load(open(p))
changed = False
for r in d['route']['rules']:
    if r.get('rule_set') == ['google-geosite', 'google-geoip']:
        if r.get('outbound') != '$new_outbound':
            r['outbound'] = '$new_outbound'
            changed = True
if changed:
    json.dump(d, open(p, 'w'), indent=2)
print('1' if changed else '0')
")"

if [ "$changed" = "1" ]; then
  sing-box check -c "$CONFIG"
  systemctl restart sing-box
  echo "Google route switched to: $target"
else
  echo "Google route already: $target (no change)"
fi
