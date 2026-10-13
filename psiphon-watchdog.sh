#!/usr/bin/env bash
# psiphon-watchdog — native (no Docker) port of Chara-Freedom/vps-psiphon's
# watchdog, re-synced 2026-10 against their current logic. One deliberate
# departure from upstream: the Google-verdict source is ads.google.com's
# locale redirect (our own earlier addition), not YouTube's embedded GL
# field — dropped entirely in this re-sync, since serverRegion + Gemini
# together already cover what it was triangulating for, without a second
# full-page fetch that breaks if Google changes its markup.
#
# Rotation triggers, in order of certainty:
#   1. socks-dead         — SOCKS does not answer at all.
#   2. denied-country     — ads.google.com places the exit in DENY_REGIONS.
#      Checked first, in every mode.
#   3. country-mismatch   — the ads.google.com verdict isn't the region
#      Psiphon itself reports for the connected server
#      (ConnectedServerRegion in notices.log). The disagreement is the
#      signal — no allow-list of regions needed.
#   4. stalled-tunnel     — SOCKS answers, but the throughput probe below
#      (a download, not a page) never completes.
#   5. slow-tunnel        — the throughput probe completes under the floor.
#      Judged over FAIL_THRESHOLD consecutive checks — a slow exit often
#      recovers on its own; everything above rotates on its first
#      occurrence, since those essentially never do.
#   6. gemini-refused     — asked at the first check of every new tunnel,
#      then every GEMINI_CHECK_SEC; Gemini keeps a geo-check of its own
#      that nothing above can see. A refusal (error 1060) is decisive.
#   - captcha is logged, never rotates on its own.
#   - no cooldown: a cooldown can only delay a rotation, never prevent one,
#     and the exit it would protect is already known bad.
#   - MAX_UPTIME_SEC forces a plain restart (same region, fresh exit IP)
#     once a tunnel gets old, regardless of any check passing — bounds
#     exposure to a stale verdict in some other Google database that
#     nothing above can read.
set -uo pipefail

. /etc/default/psiphon-watchdog

LOG=/var/log/psiphon/watchdog.log
STATE=/var/lib/psiphon/watchdog.state
NOTICES=/var/log/psiphon/notices.log
S=(--socks5-hostname "127.0.0.1:${SOCKS_PORT}")

log() { printf '%s %s\n' "$(date -Is)" "$*" >> "$LOG"; }

fails=0; last_gemini=0; gemini_tunnel=""; captcha=0
# shellcheck disable=SC1090
[ -r "$STATE" ] && . "$STATE"
now=$(date +%s)

# The tunnel this check is about — systemd instead of docker inspect.
started="$(systemctl show psiphon -p ActiveEnterTimestamp --value 2>/dev/null)"

alive=0
for attempt in 1 2; do
  code="$(curl -s -o /dev/null --max-time 20 "${S[@]}" -w '%{http_code}' \
          https://www.gstatic.com/generate_204 2>/dev/null || true)"
  [ "$code" = "204" ] && { alive=1; break; }
  [ "$attempt" = 1 ] && sleep 15
done

reason=""; ads_cc=""; sr=""; kbps=""; bulk=""
if [ "$alive" = 0 ]; then
  reason="socks-dead"
else
  ads_loc="$(curl -s -o /dev/null --max-time 15 "${S[@]}" -w '%{redirect_url}' \
             https://ads.google.com/home/ 2>/dev/null || true)"
  ads_cc="$(echo "$ads_loc" | grep -oE 'business\.google\.com/[a-z]{2}/' \
            | sed -E 's#business\.google\.com/([a-z]{2})/#\1#' | tr '[:lower:]' '[:upper:]')"

  sr="$(grep -oE '"serverRegion":"[A-Z]{2}"' "$NOTICES" 2>/dev/null | tail -1 | cut -d'"' -f4)"

  if [ -n "$ads_cc" ]; then
    case " ${DENY_REGIONS:-} " in
      *" $ads_cc "*) reason="denied-country (Google sees $ads_cc — sanctioned or Google-blocked)" ;;
    esac
    # Either side unread is not a mismatch: judging on a missing value
    # rotates for nothing.
    if [ -z "$reason" ] && [ -n "$sr" ] && [ "$ads_cc" != "$sr" ]; then
      reason="country-mismatch (Google sees $ads_cc, Psiphon connected to $sr)"
    fi
  fi

  # Throughput probe: part of a real file on Google's own download host,
  # counted from the first byte on. Its own failure (bad HTTP code) is the
  # stalled-tunnel signal too — no separate page fetch just to detect a
  # stall.
  if [ -z "$reason" ] && [ "${BULK_TEST_MB:-4}" -gt 0 ]; then
    read -r bcode bgot bfirst btotal <<<"$(curl -s -o /dev/null --max-time 25 "${S[@]}" \
      -r "0-$(( ${BULK_TEST_MB:-4} * 1048576 - 1 ))" \
      -w '%{http_code} %{size_download} %{time_starttransfer} %{time_total}' \
      https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb 2>/dev/null)"
    case "${bcode:-000}" in
      200|206)
        kbps="$(awk -v s="${bgot:-0}" -v f="${bfirst:-0}" -v t="${btotal:-0}" \
                 'BEGIN { d = t - f; print ((d > 0 && s > 0) ? int(s / d / 1024) : 0) }')"
        bulk="downloaded $(( ${bgot:-0} / 1024 )) KB at ${kbps} KB/s after first byte (${bfirst}s)"
        ;;
      *) reason="stalled-tunnel (bulk download HTTP ${bcode:-000})" ;;
    esac
  fi

  # Tunnel age, for the throughput grace period.
  up_for=999999
  if [ -n "$started" ] && [ "$started" != "n/a" ]; then
    up_for=$(( now - $(date -d "$started" +%s 2>/dev/null || echo "$now") ))
  fi

  # Plain scheduled restart once the tunnel is old enough — not a failure,
  # so it skips fail-count bookkeeping entirely and doesn't call
  # psiphon-advance-region (stays in the configured region, just gets a new
  # exit IP from it).
  if [ "${MAX_UPTIME_SEC:-0}" -gt 0 ] && [ "$up_for" -ge "${MAX_UPTIME_SEC}" ]; then
    log "scheduled restart (tunnel age ${up_for}s >= ${MAX_UPTIME_SEC}s cap) — refreshing exit IP, same region"
    systemctl restart psiphon
    cat > "$STATE" <<EOF
fails=0
last_gemini=$last_gemini
gemini_tunnel=''
captcha=0
EOF
    exit 0
  fi

  if [ -z "$reason" ] && [ -n "$kbps" ] && [ "${MIN_THROUGHPUT_KBPS:-0}" -gt 0 ]; then
    if [ "$up_for" -lt "${THROUGHPUT_GRACE_SEC:-900}" ]; then
      [ "$kbps" -lt "${MIN_THROUGHPUT_KBPS}" ] && \
        log "slow (${kbps} KB/s) but the tunnel is ${up_for}s old — still ramping, not judged"
    elif [ "$kbps" -lt "${MIN_THROUGHPUT_KBPS}" ]; then
      reason="slow-tunnel (${kbps} KB/s < ${MIN_THROUGHPUT_KBPS} KB/s floor)"
    fi
  fi

  rd="$(curl -s -o /dev/null --max-time 25 "${S[@]}" -w '%{redirect_url}' \
        'https://www.google.com/search?q=status' 2>/dev/null || true)"
  now_captcha=0; case "$rd" in */sorry/*) now_captcha=1 ;; esac
  if [ "$now_captcha" != "$captcha" ]; then
    [ "$now_captcha" = 1 ] && log "note: Google now serves a captcha to this exit (informational, no action)" \
                           || log "note: Google no longer serves a captcha to this exit"
  fi
  captcha="$now_captcha"
fi

# A restart (rotation, manual, scheduled) during this very check leaves a
# reading that belongs to neither tunnel — don't judge it.
if [ -n "$started" ] && [ "$started" != "$(systemctl show psiphon -p ActiveEnterTimestamp --value 2>/dev/null)" ]; then
  log "check not judged: the tunnel restarted during it${reason:+ (it read: $reason)}"
  exit 0
fi

decisive=0
case "$reason" in
  socks-dead*|stalled-tunnel*|denied-country*|country-mismatch*) decisive=1 ;;
esac

# Gemini is asked once per tunnel as soon as it is up — a rotation or
# restart starts a new tunnel, and an exit Gemini refuses shouldn't stand
# until the old clock runs out — and then on its own clock, since the
# answer changes over days. An inconclusive answer still counts as asked.
if [ "$alive" = 1 ] && [ "${GEMINI_CHECK_SEC:-7200}" -gt 0 ] \
   && { { [ -n "$started" ] && [ "$started" != "$gemini_tunnel" ]; } \
        || [ $((now - last_gemini)) -ge "${GEMINI_CHECK_SEC:-7200}" ]; }; then
  gem="$(/usr/local/sbin/psiphon-gemini-check 2>/dev/null)"; grc=$?
  last_gemini=$now; gemini_tunnel="$started"
  log "gemini: $gem"
  if [ "$grc" = 1 ]; then
    decisive=1
    [ -z "$reason" ] && reason="gemini-refused (error 1060 — one refusal is decisive)"
  fi
fi

if [ -z "$reason" ]; then
  [ "$fails" -gt 0 ] && log "recovered (exit $(curl -s --max-time 15 "${S[@]}" https://api.ipify.org 2>/dev/null), country ${ads_cc:-?})"
  fails=0
else
  fails=$(( fails + 1 ))
fi
[ -n "$reason" ] && log "check failed ($reason), $fails in a row"
[ -n "$kbps" ] && log "throughput ${kbps} KB/s (country ${ads_cc:-?}, server ${sr:-?})${bulk:+; $bulk}"

if [ "$fails" -ge "${FAIL_THRESHOLD:-2}" ] || [ "$decisive" = 1 ]; then
  old="$(curl -s --max-time 15 "${S[@]}" https://api.ipify.org 2>/dev/null || echo '?')"
  log "rotating away from exit $old ($reason)"
  moved="$(/usr/local/sbin/psiphon-advance-region 2>/dev/null)"
  [ -n "$moved" ] && log "region $moved"
  systemctl restart psiphon
  fails=0
fi

cat > "$STATE" <<EOF
fails=$fails
last_gemini=$last_gemini
gemini_tunnel='$gemini_tunnel'
captcha=$captcha
EOF
