#!/usr/bin/env bash
# Shared kernel/network hardening script — used on both the foreign VPS
# and the RU node. Idempotent (safe to re-run). Does NOT include the
# firewall (that's ufw-setup.sh/ru-node-ufw-setup.sh) or the SSH port
# (change that in sshd_config yourself before running the ufw script —
# see README for ordering).
set -euo pipefail

# -----------------------------------------------------------------------
# 1. BBR — congestion control. Meaningfully improves throughput/latency
#    specifically on long/potentially lossy links (RU <-> foreign VPS
#    through DPI equipment — exactly this case). Needs kernel >= 4.9,
#    ships out of the box on Ubuntu 22.04/24.04.
# -----------------------------------------------------------------------
modprobe tcp_bbr 2>/dev/null || true
grep -q '^tcp_bbr$' /etc/modules-load.d/modules.conf 2>/dev/null || echo "tcp_bbr" >> /etc/modules-load.d/modules.conf

cat > /etc/sysctl.d/98-bbr.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

# -----------------------------------------------------------------------
# 2. Network sysctl hardening — SYN flood, ICMP, source routing, backlog.
#    Note on rp_filter on the RU node: if this machine runs
#    ru-node-wdtt-routing.sh (policy routing for qWDTT), strict
#    rp_filter=1 could in theory conflict with routing that looks
#    asymmetric — the policy-routing mechanism itself (ip rule from/table)
#    shouldn't interact with rp_filter (which checks incoming packets per
#    interface, not egress decisions), but this hasn't been verified
#    empirically against real traffic. On the RU node with wdtt, set
#    IS_RU_NODE_WITH_WDTT=1 below — rp_filter then runs in loose mode
#    (=2), safer in a complex multi-interface setup. On the foreign VPS
#    (no policy routing), leave it strict (=1) — cleaner anti-spoofing.
# -----------------------------------------------------------------------
IS_RU_NODE_WITH_WDTT=0   # set to 1 on the RU node if ru-node-wdtt-routing.sh is deployed
RP_FILTER_MODE=1
[ "$IS_RU_NODE_WITH_WDTT" = "1" ] && RP_FILTER_MODE=2

cat > /etc/sysctl.d/99-network-hardening.conf <<EOF
# SYN flood
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_synack_retries = 2

# source routing / redirects — off, reduces the surface for spoofing/MITM
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0

# anti-spoofing (see the RU-node-with-wdtt note above)
net.ipv4.conf.all.rp_filter = ${RP_FILTER_MODE}
net.ipv4.conf.default.rp_filter = ${RP_FILTER_MODE}

# smurf/ICMP
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# backlog/TIME_WAIT — tuned for a proxy server with lots of short-lived connections
net.core.somaxconn = 4096
net.ipv4.tcp_max_tw_buckets = 1440000
net.ipv4.tcp_fin_timeout = 15
net.ipv4.ip_local_port_range = 10000 65535

# IPv6 fully disabled — in this setup the services (nginx, sing-box) only
# listen on IPv4, there's no outward need for IPv6 at all. Smaller
# surface, less chance of accidentally leaving something reachable with
# no firewall rule covering it (see also ufw-setup.sh/ru-node-ufw-setup.sh —
# they also set IPV6=no inside ufw itself, duplicating this protection at
# the kernel level rather than relying on ufw alone).
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF

sysctl --system > /dev/null
echo "BBR active: $(sysctl -n net.ipv4.tcp_congestion_control)"
echo "rp_filter: ${RP_FILTER_MODE} (1=strict, 2=loose)"
echo "IPv6 disabled: $(sysctl -n net.ipv6.conf.all.disable_ipv6)"

# -----------------------------------------------------------------------
# 3. Security auto-updates — the README used to only say
#    "apt install unattended-upgrades" without actually enabling it,
#    which isn't enough — the package doesn't run itself on its own.
# -----------------------------------------------------------------------
apt install -y unattended-upgrades apt-listchanges
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
systemctl enable --now unattended-upgrades

echo "Done. SSH hardening (keys/root login) — see README, applied separately by hand in sshd_config."
