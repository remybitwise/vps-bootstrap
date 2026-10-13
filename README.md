# bootstrap/ — stand up the whole stack in one run

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

```bash
DOMAIN=your.domain \
EMAIL=your@email \
SSH_PORT=your_ssh_port \
PSIPHON_EGRESS_REGION=NL \
bash bootstrap.sh
```

Optional (sensible defaults exist):
- `CLIENT_NAMES="alice bob carol"` — names of people, each gets their own
  Reality UUID and naive login/password, space separated. Defaults to one
  client, `client1`.
- `WDTT_DTLS_PORT` / `WDTT_WG_PORT` / `WDTT_TPROXY_PORT` — qWDTT ports,
  default `48219` / `48220` / `12345` (not the tool's default ports
  56000/56001 — those are the first thing mass scanning checks).
- `PSIPHON_EGRESS_REGION` — exit country code (`NL`, `DE`, `FR`...).
  Psiphon itself prints the real list of available regions to its log
  (`AvailableEgressRegions`) on first run — if the code turns out to be
  unavailable, just change the region and restart.

At the end the script prints `vless://` links, naive credentials, and
qWDTT passwords for every client. **The script does not generate the VK
call hash for qWDTT** — that's a link to a real VK group video call,
created by hand for each person, with the hash from it entered into
`/etc/wdtt/passwords.json`.

## Managing the server after setup

`manage.sh` next to this file — also self-contained, but for day-to-day
management of an already-running server:

```bash
bash manage.sh
```

An interactive menu: add/remove a client (Reality/naive/qWDTT
independently of each other), Psiphon status and exit IP/region changes,
status and restart of sing-box/caddy-naive/wdtt. `bootstrap.sh` deploys
the stack from scratch; it doesn't handle day-to-day management.

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

`bootstrap.sh` can be re-run — it pulls the latest versions of
sing-box/Caddy/qWDTT/Psiphon and fresh configs/units, but doesn't touch
what can't be regenerated:

- **Client secrets** (Reality UUIDs, naive passwords — in
  `/root/.vps-bootstrap-secrets.env`; qWDTT passwords — in
  `/etc/wdtt/passwords.json`) are generated once, read only after that.
  Links already handed to clients keep working.
- **Psiphon's region** — the watchdog's rotation can move it; a re-run
  reads the current value from the live `psiphon.config` and
  `/etc/default/psiphon-watchdog` instead of rolling it back to whatever
  was passed in `PSIPHON_EGRESS_REGION` on the first run.
- **`MIN_THROUGHPUT_KBPS` calibration** — kept if it's no longer the
  default. Every other variable in `/etc/default/psiphon-watchdog` comes
  from a fresh template each time.

Binaries update safely, not over a running process: `caddy-naive`/`wdtt`
are stopped before being replaced/rebuilt and started again, the Psiphon
binary is swapped atomically (`mv`), sing-box goes through the official
`.deb` installer.

One detail worth knowing: `ufw-setup.sh` fully reinstalls the `ufw`
package on every run (purge → install) — on a re-run this is a brief
window where the firewall is temporarily down. Not an issue on a new
machine, but worth knowing on a server already in use.
