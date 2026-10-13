# vps-bootstrap — stand up the whole stack in one run

[![CI](https://github.com/remybitwise/vps-bootstrap/actions/workflows/ci.yml/badge.svg)](https://github.com/remybitwise/vps-bootstrap/actions/workflows/ci.yml)

The folder is self-contained — everything needed lives right here, no
dependency on the rest of the repo. `bootstrap.sh` sets up on a clean
Ubuntu VPS:

- **sing-box** — VLESS+Reality (disguised as a plain HTTPS site,
  "selfsteal": invalid connections are transparently forwarded to a real
  site) + built-in **naive** — a second, independent path, a regular
  HTTPS proxy disguised as browser traffic.
- **Caddy** — in front of naive: filters requests (only the right login/
  password gets through), everything else gets the decoy page — looks
  from the outside like an ordinary, slightly unfinished personal site.
- **qWDTT** — a second camouflage protocol (WireGuard disguised as a VK
  call), for the "only allow-listed domains reachable" mode, where normal
  VPN traffic doesn't get through at all.
- **Psiphon** — a second outbound path for Google services: handles the
  case where Google flags the VPS's IP as being in a restricted country,
  with a watchdog that checks this and rotates the exit on degradation.
- **Firewall, base kernel hardening, fail2ban** — ports closed except the
  ones needed, BBR, security auto-updates, bans for password brute-force.

## Before running

1. **SSH is already set up by hand** — the key works, the port's been
   changed, password login is off. The one step the script doesn't do
   itself — see `SSH-HARDENING.md` next to this file and why it's left
   manual.
2. **A domain is bought and its A record points at this VPS.** One domain
   for everything — both for naive and as cover for Reality.
3. `EMAIL` — for Let's Encrypt, only needed to issue the certificate.

## Running it

Don't have this repo checked out yet? `install.sh` fetches it (a
tarball, no `git` needed, pinned to the latest release) and runs
`bootstrap.sh` for you, asking for anything you didn't set as an env var:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/remybitwise/vps-bootstrap/master/install.sh)
```

Already have it checked out? Run `bootstrap.sh` directly — same inputs,
no fetching:

```bash
DOMAIN=your.domain \
EMAIL=your@email \
PSIPHON_EGRESS_REGION=NL \
bash bootstrap.sh
```

Either way: `SSH_PORT` isn't listed above — it's read straight off
whatever sshd is actually listening on, set up by hand per
`SSH-HARDENING.md` before this ever runs. Set it explicitly only if you
need to override that for some reason. `bootstrap.sh` never prompts for
anything itself (so it stays predictable on a re-run) — `install.sh` is
the one place that asks, and only for whatever a first run still needs.

Optional:
- `WDTT_DTLS_PORT` / `WDTT_WG_PORT` / `WDTT_TPROXY_PORT` — qWDTT ports,
  default `48219` / `48220` / `12345` (not the tool's default ports
  56000/56001 — those are the first thing mass scanning checks).

This stands up the infrastructure with **nobody authorized to use it
yet** — no Reality/naive/qWDTT clients. Add the first person with
`manage.sh` once it finishes.

Every value here (`DOMAIN`, `SSH_PORT`, `PSIPHON_EGRESS_REGION`) comes
from an env var if you set one, or from whatever this VPS is already
running if you don't — never from an interactive prompt; a genuinely
first-time, nothing-set-up-yet run needs them spelled out (as above),
anything after that needs none of them repeated, see "Re-running"
below.

## Managing the server after setup

`manage.sh` next to this file — also self-contained, but for day-to-day
management of an already-running server:

```bash
bash manage.sh
```

An interactive menu: add/remove a client (Reality/naive/qWDTT
independently of each other), Psiphon status and exit IP/region changes,
status and restart of sing-box/caddy-naive/wdtt, and updating
sing-box/Caddy/qWDTT/Psiphon to their latest versions without re-running
`bootstrap.sh` (so no firewall/fail2ban/nginx changes along the way).
`bootstrap.sh` deploys the stack from scratch; it doesn't handle
day-to-day management.

## How it all fits together

```
Client → domain:443
           │
           ▼
     sing-box (VLESS+Reality)
           │
    valid client? ──no──► the real external site (selfsteal)
           │ yes
           ▼
    normal VPN traffic, OR the second path —
    the naive proxy (127.0.0.1:1080), in front of which
    Caddy on 8446 filters by login/password:
    wrong → decoy page, right → naive
           │
           ▼
    route.rules inside sing-box:
    Google domains → Psiphon (127.0.0.1:11080, socks)
    everything else → directly from this VPS's own IP

Separately, independently: qWDTT listens on its own port (DTLS,
disguised as a VK call) → TPROXY wraps its traffic into the
same sing-box → the same route.rules above, Psiphon for
Google included.
```

Two layers of camouflage (Reality/naive and qWDTT) — if one protocol
starts getting fingerprinted and blocked, there's somewhere to switch to
without reinstalling anything.

## Re-running updates everything to current

`bootstrap.sh` can be re-run with **no variables at all** on an
already-configured server — it installs sing-box/Caddy/qWDTT/Psiphon at
the exact versions pinned in `VERSIONS` (never "latest" — see below) and
fresh configs/units, but doesn't touch what can't be regenerated. The
same `install.sh` one-liner from
"Running it" works here too, unchanged — once `/etc/vps-bootstrap-version`
exists (written by a successful run), it fetches the latest release and
re-runs `bootstrap.sh` without asking anything at all, since there's
nothing left for it to ask about:

- **`DOMAIN`** — read back from sing-box's own config (matched by its
  `vless-reality-in` tag).
- **`SSH_PORT`** — read from whatever sshd is actually listening on.
- **`PSIPHON_EGRESS_REGION`** — the watchdog's rotation can move it; a
  re-run reads the current value from the live `psiphon.config` instead
  of rolling it back to whatever was passed on the first run.
- **`EMAIL`** — not needed at all once a certificate already exists.
- **Clients** — `bootstrap.sh` never creates or names them (that's
  `manage.sh`'s job, always); a re-run carries forward exactly whoever
  is already in sing-box's config, untouched. Nothing here to roll back
  or regenerate.
- **`MIN_THROUGHPUT_KBPS` calibration** — kept if it's no longer the
  default. Every other variable in `/etc/default/psiphon-watchdog` comes
  from a fresh template each time.

**Upstream versions are pinned, not floating.** `VERSIONS` fixes exactly
which sing-box/Caddy/qWDTT/Psiphon version `bootstrap.sh` installs, so a
release behaves the same on every server that runs it, update or not.
Need a newer version right now anyway? `manage.sh`'s update menu still
updates that one binary straight to whatever's actually latest
upstream, same as always — no compatibility guarantee, which is exactly
why that's a manual, one-binary-at-a-time action instead of what a
plain re-run does.

Changing `DOMAIN` on a re-run (a deliberate, rare operation — needs the
new domain's DNS already pointed here) issues a new certificate and
leaves the old one behind, unused. It's never deleted automatically
(Let's Encrypt allows only 5 issuances per domain per week, so an
automatic delete could cost a real retry if the change ever gets
reverted) — the script just points it out, with the exact command to
remove it by hand if you're done with it. Every existing client's
connection info has the old domain baked in and will need to be handed
out again with the new one.

Binaries update safely, not over a running process: `caddy-naive`/`wdtt`
are stopped before being replaced/rebuilt and started again, the Psiphon
binary is swapped atomically (`mv`), sing-box goes through the official
`.deb` installer.

One detail worth knowing: `ufw-setup.sh` fully reinstalls the `ufw`
package on every run (purge → install) — on a re-run this is a brief
window where the firewall is temporarily down. Not an issue on a new
machine, but worth knowing on a server already in use.

## Versioning

[`VERSION`](VERSION) and [`CHANGELOG.md`](CHANGELOG.md) follow
[Semantic Versioning](https://semver.org/) — a MAJOR bump means
something `bootstrap.sh`/`manage.sh` generate or parse changed shape
(sing-box config fields, `/etc/default/psiphon-watchdog` variable
names, `passwords.json` schema), the kind of change a re-run could
silently misread. `bootstrap.sh` stamps the version it deployed to
`/etc/vps-bootstrap-version` on a successful run; `manage.sh` shows it
in its menu header.
