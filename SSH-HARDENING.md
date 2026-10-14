# SSH — do this by hand, before running bootstrap.sh

`bootstrap.sh` leaves SSH alone on purpose. Changing the port or
disabling password login needs a check in a *new* session before
closing the old one — a script doing this unattended can lock you out
for good (console access only, if your host even has that). So: do it
by hand first, then run `bootstrap.sh`.

## 1. SSH key

A password can be brute-forced, a key can't — we'll disable password
login once the key works. All of this runs on your **local machine**.

```bash
ls ~/.ssh/id_ed25519.pub 2>/dev/null   # already have one?
```
If empty:
```bash
ssh-keygen -t ed25519 -C "vpn-server"
```
Copy it to the VPS:
```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub root@YOUR_IP
```
It'll ask for the VPS password once, to install the key — normal.

Check it logs in without a password, **in a new session**, old one
still open:
```bash
ssh -i ~/.ssh/id_ed25519 root@YOUR_IP
```

## 2. Harden sshd

New port takes you out of mass scans of port 22. Password login can go
once the key works.

On the VPS, `/etc/ssh/sshd_config` (pick a port, e.g.
`shuf -i 1025-9999 -n 1`, skip "obvious" ones like 2222):
```
Port YOUR_SSH_PORT
PasswordAuthentication no
PermitRootLogin prohibit-password
PubkeyAuthentication yes
```
```bash
sshd -t && systemctl restart sshd
```
**Check login on the new port in a new session before closing the old
one.** If it's broken, the old session can still roll `sshd_config`
back.

Once confirmed, run `bootstrap.sh` with `SSH_PORT=YOUR_SSH_PORT`.

## Already covered by bootstrap.sh

Port + no-password is the baseline. `bootstrap.sh` adds two more
layers automatically, tuned to whatever `SSH_PORT` you pass it:

- **`ufw limit ${SSH_PORT}/tcp`** — temporary kernel-level ban on too
  many connection attempts from one IP. `ufw-setup.sh`.
- **fail2ban, SSH jail** — bans an IP after repeated failed auth (5 in
  10 min → 1-hour ban by default). `fail2ban-setup.sh`.

## Optional, not part of bootstrap.sh

- **Port knocking** (`knockd`) — hides that SSH is even open until the
  right sequence arrives. Cuts scanner noise, but forget the sequence
  and you've recreated the lockout risk this whole guide avoids.
- **2FA** (`libpam-google-authenticator`) — probably overkill for a
  single key, worth it if the key's shared across people/devices.
