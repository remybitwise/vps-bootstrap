#!/usr/bin/env python3
# regen-caddyfile.py <domain> <secrets_file> <caddyfile_path>
# Used only from bootstrap.sh, on first deployment. manage.sh (day-to-day
# client management on an already-running server) keeps its own
# independent copy of the same logic — it's self-contained, no external
# dependencies, see its header.
# The list of naive clients comes from secrets_file itself (every
# CLIENT_<name>_NAIVE_PASS=... pair), not the sing-box config: that way the
# Caddyfile always matches the secrets regardless of who added what there.
import base64
import re
import sys

domain, secrets_file, caddyfile_path = sys.argv[1:4]

env = {}
with open(secrets_file) as f:
    for line in f:
        line = line.strip()
        if not line or "=" not in line:
            continue
        k, v = line.split("=", 1)
        env[k] = v

naive_creds = {}
for k, v in env.items():
    m = re.match(r"^CLIENT_(.+)_NAIVE_PASS$", k)
    if m:
        naive_creds[m.group(1)] = v

if not naive_creds:
    print("WARNING: no CLIENT_*_NAIVE_PASS entries in secrets_file — Caddyfile will reject everyone")

b64_headers = [
    # re.escape: a base64 blob can't contain "+"/"/" when built from
    # alphanumeric name:password pairs (their byte values never line up
    # to produce those two output symbols), but nothing enforces that on
    # the client name — escaping keeps a stray regex metacharacter in an
    # unusual name from changing what this header_regexp matches.
    re.escape(base64.b64encode(f"{name}:{pw}".encode()).decode())
    for name, pw in naive_creds.items()
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
print("Caddyfile written for:", sorted(naive_creds))
