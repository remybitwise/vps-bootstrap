#!/usr/bin/env bash
# install.sh — one-command launcher: fetches this repo as a tarball (no
# git required) and hands off to bootstrap.sh. Works the same way for a
# fresh VPS (first install) and for an already-configured one (update) —
# bootstrap.sh itself is purely parameter-driven with no prompts of its
# own, so this is the one place that asks a human for whatever's
# actually missing, and only when it's actually missing.
#
#   DOMAIN=your.domain EMAIL=you@mail PSIPHON_EGRESS_REGION=NL \
#     bash <(curl -fsSL https://raw.githubusercontent.com/remybitwise/vps-bootstrap/master/install.sh)
#
# On an update, run the exact same line with nothing set at all — a
# server that's already bootstrapped once never gets asked anything
# here; bootstrap.sh reads DOMAIN/SSH_PORT/PSIPHON_EGRESS_REGION back
# from what's already live and skips EMAIL entirely once a certificate
# already exists.
#
# Pinned to the latest GitHub release by default — not a moving
# "master" HEAD — so "install" (or "update") means a specific,
# deliberate version. Override with VPS_BOOTSTRAP_REF=<tag|branch|commit>
# to use something else.
set -euo pipefail

REPO="remybitwise/vps-bootstrap"
REF="${VPS_BOOTSTRAP_REF:-}"

if [ -z "$REF" ]; then
  REF="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null \
         | grep -m1 '"tag_name"' | cut -d'"' -f4)"
  if [ -z "$REF" ]; then
    echo "WARNING: could not look up the latest release, falling back to master (set VPS_BOOTSTRAP_REF to pin a version explicitly)" >&2
    REF="master"
  fi
fi

# Already bootstrapped once (this file is only ever written by a fully
# successful bootstrap.sh run) — an update, not a first install. Nothing
# below is worth asking a human for: DOMAIN/SSH_PORT/PSIPHON_EGRESS_REGION
# all come back from the live state anyway, and EMAIL is skipped once a
# certificate exists.
ALREADY_BOOTSTRAPPED=0
[ -f /etc/vps-bootstrap-version ] && ALREADY_BOOTSTRAPPED=1

if [ "$ALREADY_BOOTSTRAPPED" = "0" ]; then
  if [ -z "${DOMAIN:-}" ] && [ -t 0 ]; then
    read -rp "Domain (A record already pointing at this VPS): " DOMAIN
  fi
  if [ -z "${EMAIL:-}" ] && [ "${SKIP_CERTBOT:-0}" != "1" ] && [ -t 0 ]; then
    read -rp "Email (for the Let's Encrypt certificate): " EMAIL
  fi
  if [ -z "${PSIPHON_EGRESS_REGION:-}" ] && [ -t 0 ]; then
    read -rp "Psiphon egress region, two-letter code (e.g. NL): " PSIPHON_EGRESS_REGION
  fi
fi
# export: read above only sets a plain shell variable, which bootstrap.sh
# (a separate process below) would never otherwise see.
export DOMAIN="${DOMAIN:-}" EMAIL="${EMAIL:-}" PSIPHON_EGRESS_REGION="${PSIPHON_EGRESS_REGION:-}"

echo "Fetching ${REPO} @ ${REF}..."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# GitHub's shorthand archive URL accepts a tag, a branch, or a commit SHA
# the same way — no need to know which REF is up front.
curl -fsSL "https://github.com/${REPO}/archive/${REF}.tar.gz" -o "$tmp/src.tar.gz"
tar xzf "$tmp/src.tar.gz" -C "$tmp" --strip-components=1

bash "$tmp/bootstrap.sh"
