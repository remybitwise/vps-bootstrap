# SSH — do this by hand, before running bootstrap.sh

`bootstrap.sh` in this folder deliberately leaves SSH alone entirely. Not
laziness — caution: changing the port/disabling password login needs a
login check in a NEW session, without closing the old one, before you go
on. A script doing this with no human watching can lock you out of the
server permanently (close the one session and that's it, the server's
only reachable through the host's console). This is the one step in the
whole setup that's intentionally not automated — do it by hand, following
the steps below, and only then run `bootstrap.sh`.

## 1. SSH key

A password can be brute-forced, a key can't, so after this we'll disable
password login entirely. The key has to work before that happens.

Everything here is on your **local machine**.

```bash
ls ~/.ssh/id_ed25519.pub 2>/dev/null   # already have one?
```
If empty:
```bash
ssh-keygen -t ed25519 -C "vpn-server"
```
Copy it to the VPS (`YOUR_IP` — your server's real address):
```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub root@YOUR_IP
```
It'll ask for the VPS password — that's normal, type it: it logs in with
it once to write the key to the server, won't be needed after that.

Check that it logs in without a password, **in a new session**, without
closing the old one:
```bash
ssh -i ~/.ssh/id_ed25519 root@YOUR_IP
```

## 2. SSH hardening

Changing the port takes SSH out from under mass automated scans of port
22. Disabling the password — once the key already works, a password as a
login method just adds risk and isn't needed anymore.

On the VPS, `/etc/ssh/sshd_config` (pick your own port, e.g. via
`shuf -i 1025-9999 -n 1`, avoiding "obvious" ones like 2222):
```
Port YOUR_SSH_PORT
PasswordAuthentication no
PermitRootLogin prohibit-password
PubkeyAuthentication yes
```
```bash
sshd -t && systemctl restart sshd
```
**Check login on the new port in a new session, without closing the old
one, and only then continue.** If something's wrong, you still have a
working old session to roll `sshd_config` back.

Only once key login on the new port is confirmed — run `bootstrap.sh`
with `SSH_PORT=YOUR_SSH_PORT`.

## What else protects SSH — already part of bootstrap.sh, just a reminder

Changing the port and disabling passwords is the baseline, not the only
layer. `bootstrap.sh` adds two more on top, both already verified live in
this project:

- **`ufw limit ${SSH_PORT}/tcp`** (`limit`, not `allow`) — throttles
  brute-force attempts at the firewall level: too many connections from
  one IP get a temporary kernel-level ban before it even reaches sshd.
  Part of `ufw-setup.sh`, step 1 in `bootstrap.sh`.
- **fail2ban, SSH jail** — reads `auth.log`, bans an IP after several
  failed auth attempts (default: 5 attempts in 10 minutes → a one-hour
  ban). Part of `fail2ban-setup.sh`, step 11 in `bootstrap.sh`.

Both are already configured for your `SSH_PORT` as soon as it's passed to
`bootstrap.sh` — no separate tuning needed.

## Optional, not part of bootstrap.sh

For going further — not documented or verified live in this project, so
not included by default:

- **Moving SSH to a nonstandard protocol/port knocking** (`knockd`) —
  hides the fact that the SSH port is even open until the right knock
  sequence arrives. Cuts a lot of noise from mass scanners, but adds its
  own failure point (forget the sequence and you're in the same
  lockout risk this whole guide exists to avoid) and one more component
  to maintain.
- **2FA for SSH** (`libpam-google-authenticator`) — a second factor on
  top of the key. For a single root key that's already not brute-
  forceable, probably overkill, but can make sense if the key is shared
  across several devices/people.
