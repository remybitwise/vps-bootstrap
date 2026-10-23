# Changelog

[Semantic Versioning](https://semver.org/): MAJOR when `bootstrap.sh`/
`manage.sh` generate or parse something whose shape changed (sing-box
config fields, `psiphon-watchdog` env vars, `passwords.json` schema,
service-unit layout) — the kind of change that can make a re-run
silently lose or misread state. MINOR for new backward-compatible
stuff. PATCH for fixes.

`/etc/vps-bootstrap-version` on a deployed server records what's
actually running there.

## [3.0.2] - 2026-10-23

Removing a client's Reality/naive/qWDTT left their personal
always-direct route rule behind, dead but still sitting in
`config.json` — `manage.sh`'s remove flow now drops it too (and the
matching `CLIENT_<name>_ROUTE_*` secrets line), same as it already
did for the UUID/naive password. qWDTT's rule is keyed by device IP,
not by client — if another remaining client shares that IP, the rule
stays, since removing one of them doesn't mean the device's traffic
should stop routing direct.

## [3.0.1] - 2026-10-23

`bootstrap.sh` sourced the secrets file as a shell script to pull in
`REALITY_PRIVATE_KEY`/`REALITY_PUBLIC_KEY`/`SHORT_ID` — a client name
with a `-` (not valid in a bash identifier) made that line fail as
"command not found" and aborted the whole run. Those three are read
back through the same python parsing every `CLIENT_*` line already
goes through; the sourcing wasn't actually needed for anything.

## [3.0.0] - 2026-10-23

**BREAKING:** the always-direct Google/YouTube toggle (2.4.0) now
switches Reality, naive, and qWDTT independently per client instead of
all-or-nothing. `CLIENT_<name>_ROUTE=direct` in the secrets file is
gone — replaced by `CLIENT_<name>_ROUTE_REALITY`/`_NAIVE`/`_WDTT`.
A server still on the old flag needs it migrated by hand (drop the old
line, add the matching new one(s)) before re-running `bootstrap.sh`,
or that client's direct routing silently reverts to the normal Psiphon
switch on the next re-run.

`manage.sh`'s toggle menu item now asks which protocol to flip for a
client that has more than one (Reality/naive matched by `user` +
`inbound` together now, not `user` alone — so naive stays on Psiphon
while Reality goes direct, or vice versa). `list_clients` shows each
protocol's routing state separately instead of one shared tag.

## [2.4.0] - 2026-10-23

Google/YouTube routing now goes through a sing-box `selector` outbound
(`google-out`), flipped live over sing-box's own Clash API instead of
rewriting `config.json` and restarting — `singbox-google-route.sh`
(used by `manage.sh` and `psiphon-watchdog.sh`) no longer interrupts
every client on a switch, only the Google-bound connections actually
affected. The choice survives a later restart on its own
(`cache_file`), so an unrelated `manage.sh` client add/remove or a
`bootstrap.sh` re-run can't silently revert it back to Psiphon anymore.

New `manage.sh` menu item: toggle a given client onto always-direct
Google/YouTube routing, bypassing Psiphon (and the switch above)
entirely for just that client — for when Psiphon's extra hop isn't
worth it for a specific use. Works for qWDTT clients too, matched by
their device's tunnel IP since TPROXY traffic has no sing-box "user".

## [2.3.1] - 2026-10-14

`show_client_config` (menu item 4): asks what to show (everything /
links only / JSON only) before printing. Reality and naive now share
one combined sing-box JSON (`proxy-reality`/`proxy-naive` tags) instead
of two separate blocks. qWDTT's `vk_hash` requirement was only ever
real for `wdtt://` (iOS, positional field) — `qwdtt://` (Android) omits
`hashes=` entirely when none is set instead of warning about it; the
qWDTT server itself never reads `vk_hash` either way (only the unused
bot/admin API does).

## [2.3.0] - 2026-10-14

`vps-manage`'s menu, reshuffled: dropped "Tail watchdog log" and
"Restart sing-box/caddy-naive/wdtt" (both trivially doable by hand over
SSH), added "Show client config" — prints an existing client's vless
link + sing-box JSON for Reality/naive, and `wdtt://`/`qwdtt://` links
for qWDTT. Menu item numbers shifted; anything scripting `manage.sh`'s
stdin needs to account for that.

`bootstrap.sh` now skips reinstalling a binary that's already at least
as new as its `VERSIONS` pin — sing-box/Caddy by comparing the real
installed version, qWDTT/Psiphon (no version command to check) by
remembering the last ref it installed. A manual update via `manage.sh`
is never rolled back on the next re-run: sing-box/Caddy because a newer
real version already satisfies the pin, qWDTT/Psiphon because that
update marks the component overridden, left alone for good unless
`FORCE_REINSTALL=qwdtt,psiphon` (etc.) says otherwise.

qWDTT's build no longer keeps the cloned repo around (it only ever
built `./server`) — a throwaway temp dir instead, deleted once the
binary's in place.

## [2.2.1] - 2026-10-14

The Psiphon binary download had no retry — a dropped connection
partway through killed the whole `bootstrap.sh` run. Now retries up
to 5 times on both the `bootstrap.sh` and `manage.sh` copies.

## [2.2.0] - 2026-10-14

`bootstrap.sh` now installs `manage.sh` to `/usr/local/sbin/vps-manage`
(already on PATH), kept current on every re-run — no more needing the
repo checked out just to run it.

## [2.1.0] - 2026-10-14

Upstream sing-box/Caddy/qWDTT/Psiphon versions are now pinned in
`VERSIONS` instead of `bootstrap.sh` always grabbing "latest".
`manage.sh`'s per-binary update menu still goes straight to latest —
that's the deliberate manual escape hatch.

A weekly `dep-bump.yml` workflow opens a PR when upstream moves,
gated by the normal CI run.

- Caddy's pinned version downloads directly by its release-asset URL
  instead of through `api.github.com`, which is rate-limited per IP
  and was flaking in CI (shared runner IPs).
- `manage.sh`'s qWDTT "update to latest" fetched `origin` with no ref,
  which can land on whatever branch the remote listed last. Now
  fetches `origin HEAD` explicitly.

## [2.0.0] - 2026-10-14

**BREAKING:** `bootstrap.sh` no longer creates clients. A first run
stands up the infrastructure with nobody authorized yet — add the
first person with `manage.sh`. Anyone using the old `CLIENT_NAMES` env
var needs to switch.

- `CLIENT_NAMES` is gone — sing-box config regen now carries forward
  whatever clients are already live instead of rebuilding from a name
  list.
- No more interactive prompts in `bootstrap.sh` — every value comes
  from an env var, this VPS's own state, or a hard failure.
- New `install.sh`: fetches the repo as a tarball (no `git` needed)
  and runs `bootstrap.sh`. Same one-liner for first install and
  update — it only prompts when nothing's bootstrapped yet.
- `DOMAIN` detection now matches sing-box's `vless-reality-in` tag
  instead of assuming it's the first inbound.
- `SSH_PORT` detection now reads the actually-listening sshd process
  instead of parsing `sshd_config` text.
- A domain change on a re-run prints a reminder about the old
  certificate instead of deleting it automatically.

## [1.1.0] - 2026-10-14

- **Google direct-fallback failover.** If Psiphon can't recover after
  exhausting `REGION_POOL`, Google traffic routes directly from the
  VPS's own IP instead of failing outright. Switches back once a
  region checks clean twice in a row. New: `singbox-google-route.sh`.
- `psiphon.service` now has `OnFailure=psiphon-watchdog.service` —
  a crash fires the watchdog immediately instead of waiting for the
  timer.
- `psiphon-watchdog.timer`: 10min → 5min.
- `manage.sh`'s Psiphon status shows where Google traffic is routed.

## [1.0.0] - 2026-10-13

Initial tagged baseline.

- sing-box (VLESS+Reality + naive), Caddy (naive camouflage + decoy),
  qWDTT (TPROXY whitelist bypass), Psiphon (second egress for Google)
  + watchdog, firewall, kernel hardening, fail2ban.
- `manage.sh`: client management, Psiphon status/exit-IP/region
  changes, service status/restart, binary updates.
- `bootstrap.sh` is idempotent — re-running it updates everything to
  current while preserving client secrets and live settings.
- CI: lint on every push, plus a full deploy + client-connection +
  `manage.sh` functional test.
