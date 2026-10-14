#!/usr/bin/env bash
# install.sh — fetches this repo as a tarball (no git needed) and hands
# off to bootstrap.sh. Same command for a fresh install and an update;
# it's the only place that prompts, and only for what's actually missing.
#
#   DOMAIN=your.domain EMAIL=you@mail PSIPHON_EGRESS_REGION=NL \
#     bash <(curl -fsSL https://raw.githubusercontent.com/remybitwise/vps-bootstrap/master/install.sh)
#
# Pinned to the latest GitHub release by default. Override with
# VPS_BOOTSTRAP_REF=<tag|branch|commit>.
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

# This file only exists after a successful bootstrap.sh run — if it's
# there, nothing below is worth asking about.
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
