#!/usr/bin/env bash
# Runs after bootstrap.sh on a CI runner, as root. Confirms the two main
# client paths actually carry traffic end to end (not just that the
# services report "active"), plus qWDTT and Psiphon coming up for real.
set -euo pipefail

DOMAIN="${DOMAIN:?set DOMAIN}"
CLIENT_NAME="${CLIENT_NAME:?set CLIENT_NAME}"
FAIL=0

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

echo "--- Reality + naive: real client -> server -> Psiphon-out -> gstatic ---"
test_client "$DOMAIN" "$CLIENT_NAME" || true

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

exit "$FAIL"
