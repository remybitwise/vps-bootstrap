#!/usr/bin/env python3
# regen-caddyfile.py <domain> <sing_box_config> <caddyfile_path>
# Used only from bootstrap.sh, on first deployment. manage.sh (day-to-day
# client management on an already-running server) keeps its own
# independent copy of the same logic — it's self-contained, no external
# dependencies, see its header.
# The list of naive clients comes from sing-box's own config (its
# naive-in inbound's users) — the one place clients are added or removed
# (via manage.sh), so the Caddyfile always matches exactly who sing-box
# will actually accept.
import base64
import json
import re
import sys

domain, sing_box_config, caddyfile_path = sys.argv[1:4]

# bootstrap.sh calls this before sing-box's own config exists yet on a
# first run (Caddy is set up one step before sing-box) — but the package
# install (step 0, earlier) can leave its own stock example config.json
# at this same path, with a shape that's not ours at all (no "tag" on
# its inbounds). Either way — no file, or a file that isn't the one
# bootstrap.sh itself writes — means no naive users yet, same as any
# other first-run default.
try:
    d = json.load(open(sing_box_config))
    naive_users = next((i.get("users", []) for i in d.get("inbounds", []) if i.get("tag") == "naive-in"), [])
except (FileNotFoundError, json.JSONDecodeError):
    naive_users = []

if not naive_users:
    print("WARNING: no naive users in sing-box's config — Caddyfile will reject everyone")

b64_headers = [
    # re.escape: a base64 blob can't contain "+"/"/" when built from
    # alphanumeric name:password pairs (their byte values never line up
    # to produce those two output symbols), but nothing enforces that on
    # the client name — escaping keeps a stray regex metacharacter in an
    # unusual name from changing what this header_regexp matches.
    re.escape(base64.b64encode(f"{u['username']}:{u['password']}".encode()).decode())
    for u in naive_users
]
pattern = "|".join(b64_headers)

caddyfile = f'''{{
	admin off
	auto_https off
	log {{
		exclude http.log.error
	}}
}}

:8446 {{
	bind 127.0.0.1
	tls /etc/letsencrypt/live/{domain}/fullchain.pem /etc/letsencrypt/live/{domain}/privkey.pem
	encode
	header -Server
	header -Alt-Svc

	@naive {{
		method CONNECT
		header_regexp Proxy-Authorization "^Basic ({pattern})$"
	}}
	handle @naive {{
		reverse_proxy 127.0.0.1:1080 {{
			transport http {{
				versions h2c
			}}
			header_up Proxy-Authorization {{http.request.header.Proxy-Authorization}}
		}}
	}}
	handle {{
		root * /var/www/html
		file_server
	}}
}}
'''
open(caddyfile_path, "w").write(caddyfile)
print("Caddyfile written for:", sorted(u["username"] for u in naive_users))
