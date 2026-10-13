# Changelog

Versions follow [Semantic Versioning](https://semver.org/): **MAJOR** when
something `bootstrap.sh` or `manage.sh` generates or parses changes shape
(sing-box config fields, `/etc/default/psiphon-watchdog` variable names,
`passwords.json` schema, service-unit layout any of these scripts grep
out of) — those are the changes that can make a re-run silently lose or
misread state. **MINOR** for anything new that's backward compatible.
**PATCH** for fixes only.

`/etc/vps-bootstrap-version` on a deployed server records which version
is actually running there, written by `bootstrap.sh` on a successful run.

## [Unreleased]

Upstream sing-box/Caddy/qWDTT/Psiphon versions are now pinned in
`VERSIONS` instead of `bootstrap.sh` always fetching "latest" — a
release's behavior no longer depends on what upstream happens to ship
on deploy day. `manage.sh`'s per-binary update menu is unchanged and
still goes straight to latest — that's the deliberate "update this one
thing right now, no compatibility guarantee" escape hatch.

## [2.0.0] - 2026-10-14

**BREAKING:** `bootstrap.sh` no longer creates any clients. A first run
now stands up the infrastructure with nobody authorized to use it yet —
add the first person with `manage.sh`, same as any client after that.
Anyone relying on the old `CLIENT_NAMES` env var or the client
links/configs `bootstrap.sh` used to print at the end needs to switch to
`manage.sh` for that.

- `CLIENT_NAMES` is gone. The sing-box config regeneration carries
  forward whatever clients are already in the live config instead of
  rebuilding the user lists from a name list — a re-run can no longer
  `KeyError` on a client that only has one of Reality/naive (manage.sh
  already allowed that; the old per-name rebuild didn't handle it).
  `regen-caddyfile.py` now reads naive credentials from sing-box's own
  config too, matching `manage.sh`'s copy of the same logic exactly
  instead of a separate secrets-file-based path.
- No more interactive prompts anywhere in `bootstrap.sh` — every value
  resolves from an env var, or this VPS's own already-deployed state, or
  a hard failure.
- New `install.sh`: a one-command launcher (fetches this repo as a
  tarball, no `git` needed, pinned to the latest release by default)
  that asks for whatever a genuine first run still needs, then runs
  `bootstrap.sh`. The same one-liner updates an already-bootstrapped
  server with no prompts at all — it only asks on a server that's never
  been bootstrapped (`/etc/vps-bootstrap-version` missing).
- `DOMAIN` auto-detection now matches sing-box's `vless-reality-in` tag
  instead of assuming it's the first inbound in the list.
- `SSH_PORT` auto-detection now reads the actually-listening sshd
  process (`ss`) instead of parsing `sshd_config` text — fixes both the
  multiple-`Port`-lines case and the no-`Port`-line-at-all case (which
  means the default, 22, not "undetectable").
- A domain change (rare, deliberate — passing a different `DOMAIN` on a
  re-run) now prints a reminder about the old certificate left behind,
  with the exact `certbot delete --cert-name` to remove it by hand.
  Never deleted automatically.

## [1.1.0] - 2026-10-14

- **Google direct-fallback failover.** If Psiphon can't recover — every
  region in `REGION_POOL` tried and failed, `REGION_SWEEPS_BEFORE_DIRECT`
  times in a row — Google-destined traffic is routed directly from the
  VPS's own IP instead of failing outright. Switches back the moment one
  region checks clean twice in a row. New: `singbox-google-route.sh`
  (flips sing-box's route for Google traffic, idempotent). Backward
  compatible: `region_cycle_fails`/`via_direct`/`clean_streak` in
  `watchdog.state` default to 0 when absent (an old state file just
  works), and `REGION_SWEEPS_BEFORE_DIRECT=0` disables the fallback
  entirely if ever needed.
- `psiphon.service` now has `OnFailure=psiphon-watchdog.service` — an
  actual crash fires the watchdog immediately instead of waiting for the
  timer.
- `psiphon-watchdog.timer`: 10min → 5min, now that `OnFailure=` covers
  instant reaction to a real crash and the timer only needs to catch
  slower degradation (slow throughput, wrong region, Gemini refusing).
- `manage.sh`'s Psiphon status now shows where Google traffic is
  currently routed.

## [1.0.0] - 2026-10-13

Initial tagged baseline.

- sing-box (VLESS+Reality + naive), Caddy (naive camouflage + decoy),
  qWDTT (TPROXY whitelist bypass), Psiphon (second egress for Google) +
  watchdog, firewall, kernel hardening, fail2ban.
- `manage.sh`: client management (Reality/naive/qWDTT, independently),
  Psiphon status/exit-IP/region changes, service status/restart, and
  updating sing-box/Caddy/qWDTT/Psiphon to their latest versions without
  a full `bootstrap.sh` re-run.
- `bootstrap.sh` is idempotent: re-running it updates every binary and
  config to current, while preserving client secrets, the live Psiphon
  region, and any non-default throughput calibration.
- CI (`.github/workflows/ci.yml`): lint on every push, plus a full
  deploy + real-client-connection + `manage.sh` functional test on an
  ubuntu-latest runner.
