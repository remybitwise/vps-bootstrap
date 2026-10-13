#!/usr/bin/env bash
# Advances EgressRegion in /etc/psiphon/psiphon.config to the next country in
# REGION_POOL (from /etc/default/psiphon-watchdog) and prints "old -> new".
# Silent (no output, no change) when REGION_POOL is empty — single fixed region.
set -uo pipefail
. /etc/default/psiphon-watchdog
CONFIG=/etc/psiphon/psiphon.config

[ -z "${REGION_POOL:-}" ] && exit 0

current="$(python3 -c "import json; print(json.load(open('$CONFIG')).get('EgressRegion',''))" 2>/dev/null)"

# shellcheck disable=SC2206
pool=(${REGION_POOL})
next=""
for i in "${!pool[@]}"; do
  if [ "${pool[$i]}" = "$current" ]; then
    idx=$(( (i + 1) % ${#pool[@]} ))
    next="${pool[$idx]}"
    break
  fi
done
[ -z "$next" ] && next="${pool[0]}"
[ "$next" = "$current" ] && exit 0

python3 -c "
import json
p = '$CONFIG'
d = json.load(open(p))
d['EgressRegion'] = '$next'
json.dump(d, open(p, 'w'), indent=2)
"
sed -i "s/^EGRESS_REGION=.*/EGRESS_REGION=$next/" /etc/default/psiphon-watchdog
echo "$current -> $next"
