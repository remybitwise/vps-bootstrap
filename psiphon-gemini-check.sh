#!/usr/bin/env bash
# psiphon-gemini-check — asks Gemini itself whether it serves the current
# Psiphon exit. Not a proxy check ("is this country on some list") — the
# actual target service: avoiding exactly this refusal is the original
# reason this whole Psiphon setup exists, see PSIPHON.md. Ported from
# Chara-Freedom/vps-psiphon.
#
# Logged out: the page is fetched for its session fields and cookies, then
# one anonymous message is sent.
#
# Prints one line and exits:
#   exit 0  ok            Gemini replied; the line names the place it puts us in
#   exit 1  REFUSED       error 1060 and no reply: Gemini declines this exit
#   exit 2  inconclusive  anything else — never grounds for a rotation
set -uo pipefail
[ -r /etc/default/psiphon-watchdog ] && . /etc/default/psiphon-watchdog
P=(--socks5-hostname "127.0.0.1:${SOCKS_PORT:-11080}")
UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36'
d="$(mktemp -d)" || { echo "inconclusive (no temp dir)"; exit 2; }
trap 'rm -rf "$d"' EXIT
C=(-s "${P[@]}" -A "$UA" -H 'Accept-Language: en-US,en;q=0.9' -b "$d/jar" -c "$d/jar")

code="$(curl "${C[@]}" --max-time 30 -o "$d/app" -w '%{http_code}' https://gemini.google.com/app 2>/dev/null || true)"
bl="$(grep -oE '"cfb2h":"[^"]+"' "$d/app" 2>/dev/null | head -1 | cut -d'"' -f4)"
sid="$(grep -oE '"FdrFJe":"[^"]+"' "$d/app" 2>/dev/null | head -1 | cut -d'"' -f4)"
if [ -z "$bl" ] || [ -z "$sid" ]; then
  echo "inconclusive (page answered ${code:-nothing}, without the session fields)"; exit 2
fi

curl "${C[@]}" --max-time 60 -o "$d/out" \
  -H 'Content-Type: application/x-www-form-urlencoded;charset=utf-8' \
  -H 'Origin: https://gemini.google.com' -H 'Referer: https://gemini.google.com/' -H 'X-Same-Domain: 1' \
  --data-urlencode 'f.req=[null,"[[\"hi\"],null,null]"]' \
  "https://gemini.google.com/_/BardChatUi/data/assistant.lamda.BardFrontendService/StreamGenerate?bl=${bl}&f.sid=${sid}&hl=en&_reqid=$(( RANDOM * 10 + 100000 ))&rt=c" 2>/dev/null

# A reply is a frame whose payload is not null. Error codes can trail a
# reply, so they're only read when no reply came at all.
if grep -q '"wrb.fr",null,"\[' "$d/out" 2>/dev/null; then
  where="$(grep -oE '\\"[^"\\]+\\",\\"SWML_DESCRIPTION' "$d/out" | head -1 | cut -d'"' -f2 | tr -d '\\')"
  echo "ok — Gemini replies, and places this exit in ${where:-an unnamed country}"; exit 0
fi
errs="$(grep -oE 'BardErrorInfo",\[[0-9]+\]' "$d/out" 2>/dev/null | grep -oE '[0-9]+' | sort -u | tr '\n' ' ')"
case " $errs " in
  *" 1060 "*) echo "REFUSED — Gemini declines this exit (error 1060, no reply)"; exit 1 ;;
esac
echo "inconclusive (no reply${errs:+, error ${errs% }})"; exit 2
