# vps-bootstrap — stand up the whole stack in one run

[![Release](https://img.shields.io/github/v/release/remybitwise/vps-bootstrap)](https://github.com/remybitwise/vps-bootstrap/releases/latest)
[![CI](https://github.com/remybitwise/vps-bootstrap/actions/workflows/ci.yml/badge.svg)](https://github.com/remybitwise/vps-bootstrap/actions/workflows/ci.yml)
[![Dependency bump check](https://github.com/remybitwise/vps-bootstrap/actions/workflows/dep-bump.yml/badge.svg)](https://github.com/remybitwise/vps-bootstrap/actions/workflows/dep-bump.yml)

- **sing-box** — VLESS+Reality (looks like a plain HTTPS site; invalid
  connections get forwarded to a real site) plus built-in **naive**, a
  second proxy disguised as regular browser traffic.
- **Caddy** — sits in front of naive, filters by login/password, wrong
  creds get a decoy page that looks like an ordinary unfinished site.
- **qWDTT** — second camouflage protocol (WireGuard disguised as a VK
  call), for networks where only allow-listed domains are reachable.
- **Psiphon** — second outbound path for Google traffic, for when
  Google flags the VPS's IP as being in a restricted country.
- **Firewall, kernel hardening, fail2ban** — closed ports, BBR, auto
  security updates, brute-force bans.

## Before running

1. **SSH already set up by hand** — key works, port changed, password
   login off. See `SSH-HARDENING.md`, the one step this doesn't automate.
2. **A domain bought, A record pointing at this VPS.** Used for both
   naive and as cover for Reality.
3. `EMAIL` — for Let's Encrypt.

## Running it

No repo checked out yet? `install.sh` fetches it and runs `bootstrap.sh`
for you, asking only for what you haven't set as an env var:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/remybitwise/vps-bootstrap/master/install.sh)
```

Already checked out? Run `bootstrap.sh` directly:

```bash
DOMAIN=your.domain \
EMAIL=your@email \
PSIPHON_EGRESS_REGION=NL \
bash bootstrap.sh
```

`SSH_PORT` isn't listed — it's read off whatever sshd is actually
listening on. Set it explicitly only to override that. `bootstrap.sh`
never prompts for anything; `install.sh` is the only place that asks,
and only for what a first run still needs.

Optional:
- `WDTT_DTLS_PORT` / `WDTT_WG_PORT` / `WDTT_TPROXY_PORT` — qWDTT ports,
  default `48219` / `48220` / `12345` (not the tool's own defaults
  56000/56001 — those get hit by mass scanning first).

First run stands up the infrastructure with **no clients yet**. Add the
first one with `manage.sh`.

## Managing the server

`manage.sh` — day-to-day management of an already-running server:

```bash
bash manage.sh
```

Add/remove clients (Reality/naive/qWDTT, independently), Psiphon status
and exit IP/region changes, service status/restart, and updating
sing-box/Caddy/qWDTT/Psiphon without touching firewall/fail2ban/nginx.

## How it fits together

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

Separately: qWDTT listens on its own port (DTLS, disguised as a VK
call) → TPROXY wraps its traffic into the same sing-box → same
route.rules above, Psiphon for Google included.
```

Two independent camouflage protocols — if one gets fingerprinted and
blocked, there's somewhere to switch to without reinstalling anything.

## Re-running updates everything in place

`bootstrap.sh` can be re-run with no variables at all on an already
set-up server. It reinstalls sing-box/Caddy/qWDTT/Psiphon at the
versions pinned in `VERSIONS`, regenerates configs, and leaves
everything else as-is:

- `DOMAIN`, `SSH_PORT`, `PSIPHON_EGRESS_REGION` — read back from the
  live server, not asked again.
- `EMAIL` — skipped once a certificate already exists.
- Clients — carried forward exactly as they are. `bootstrap.sh` never
  creates or touches them; that's `manage.sh`'s job.
- `MIN_THROUGHPUT_KBPS` — kept if it's been tuned away from default.

Upstream versions are pinned in `VERSIONS`, not floating — a release
behaves the same on every server it runs on. A weekly workflow
(`dep-bump.yml`) opens a PR when upstream moves, gated by CI. Need a
newer version right now anyway? `manage.sh`'s update menu still grabs
latest for one binary at a time, no compatibility guarantee.

Changing `DOMAIN` on a re-run issues a new certificate and leaves the
old one behind — never deleted automatically (Let's Encrypt allows
only 5 issuances per domain per week). The script prints the exact
`certbot delete` command if you want it gone. Existing clients will
need their connection info re-sent with the new domain.

Binaries update without touching a running process: `caddy-naive`/
`wdtt` stop before replace and restart after, Psiphon's binary swaps
atomically, sing-box goes through its own `.deb` installer.

One thing to know: `ufw-setup.sh` reinstalls the `ufw` package on every
run, which means a brief window with the firewall down. Fine on a new
machine, worth knowing on one already in use.

## Versioning

[`VERSION`](VERSION) and [`CHANGELOG.md`](CHANGELOG.md) follow
[Semantic Versioning](https://semver.org/) — MAJOR means something
`bootstrap.sh`/`manage.sh` generate or parse changed shape, the kind of
change a re-run could silently misread. `bootstrap.sh` stamps the
deployed version to `/etc/vps-bootstrap-version`; `manage.sh` shows it
in its menu header.
