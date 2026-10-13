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
