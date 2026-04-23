#!/usr/bin/env bash
# setup-tcp.sh – Apply TCP/IP stack tuning to mimic a Windows 10 network fingerprint
# Must be run as root.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
fatal() { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }

[[ $EUID -ne 0 ]] && fatal "Run as root: sudo bash setup-tcp.sh"

# ─── 1. sysctl – kernel TCP/IP parameters ────────────────────────────────────
info "Writing sysctl tuning to /etc/sysctl.d/99-proxy-tuning.conf ..."

cat > /etc/sysctl.d/99-proxy-tuning.conf << 'SYSCTL'
# ── TTL = 128 (Windows 10 default, vs Linux default 64) ──────────────────────
net.ipv4.ip_default_ttl = 128

# ── TCP Timestamps OFF (Windows 10 does not advertise timestamps by default) ──
net.ipv4.tcp_timestamps = 0

# ── SACK ON (Selective ACK – present in Windows 10) ──────────────────────────
net.ipv4.tcp_sack = 1

# ── TCP Window Scaling ON (Windows 10 uses scaling, autotune) ─────────────────
net.ipv4.tcp_window_scaling = 1

# ── Initial receive/send buffer = 65535 bytes (Windows 10 advertises 65535) ──
net.core.rmem_default = 65536
net.core.wmem_default = 65536
net.core.rmem_max     = 16777216
net.core.wmem_max     = 16777216
net.ipv4.tcp_rmem = 4096 65536 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# ── ECN OFF (Windows 10 sends ECN=0 in SYN by default) ───────────────────────
net.ipv4.tcp_ecn = 0

# ── Disable TCP slow-start after idle (more Windows-like burst behaviour) ─────
net.ipv4.tcp_slow_start_after_idle = 0

# ── Path MTU discovery ON ─────────────────────────────────────────────────────
net.ipv4.ip_no_pmtu_disc = 0

# ── Disable TCP MTU probing (prevents kernel lowering MSS based on ICMP) ──────
# Keeps MSS stable at 1460 even when upstream tunnel has lower MTU (e.g. 1238)
net.ipv4.tcp_mtu_probing = 0

# ── Reduce TIME_WAIT sockets (not fingerprint-related, just good practice) ────
net.ipv4.tcp_fin_timeout = 15
SYSCTL

sysctl --system > /dev/null 2>&1
info "sysctl applied."

# ─── 2. MTU = 1500 on all non-loopback interfaces ────────────────────────────
info "Setting MTU = 1500 on all physical interfaces ..."
while IFS= read -r iface; do
    current_mtu=$(ip link show "$iface" | awk '/mtu/{for(i=1;i<=NF;i++) if($i=="mtu") print $(i+1)}')
    if [[ "$current_mtu" != "1500" ]]; then
        ip link set "$iface" mtu 1500 2>/dev/null && info "  $iface: MTU set to 1500" \
            || warn "  $iface: could not set MTU (virtual/tunnel interface?)"
    else
        info "  $iface: MTU already 1500"
    fi
done < <(ip -o link show | awk -F': ' '{print $2}' | cut -d@ -f1 | grep -v '^lo$')

# ─── 3. iptables – TCPMSS clamp + strip TCP timestamps from outbound packets ──
info "Configuring iptables rules ..."

# Load required kernel modules
modprobe xt_TCPMSS 2>/dev/null || warn "xt_TCPMSS module not available (skip)"

# Helper: idempotent rule add (only add if rule doesn't already exist)
ipt_add() {
    if ! iptables -t mangle -C "$@" 2>/dev/null; then
        iptables -t mangle -A "$@"
    fi
}

# ── Clamp MSS = 1460 (1500 MTU - 20 IP - 20 TCP) on ALL chains ───────────────
#
# PREROUTING : rewrite MSS in SYN-ACK coming FROM upstream (may be 1198 due to
#              their internal IPIP/GRE tunnel with MTU 1238) → hides IPIP/SIT
#              interface type from passive fingerprinters like p0f/browserleaks
# OUTPUT     : rewrite MSS in SYN we send to ANY destination (browserleaks etc)
#              so we always advertise Ethernet-class MSS regardless of VPS tunnel
# FORWARD    : for bridged/routed traffic
# POSTROUTING: catch-all for anything not hit above

ipt_add PREROUTING  -p tcp --tcp-flags SYN,RST SYN     -j TCPMSS --set-mss 1460
ipt_add PREROUTING  -p tcp --tcp-flags SYN,ACK SYN,ACK -j TCPMSS --set-mss 1460
ipt_add OUTPUT      -p tcp --tcp-flags SYN,RST SYN     -j TCPMSS --set-mss 1460
ipt_add FORWARD     -p tcp --tcp-flags SYN,RST SYN     -j TCPMSS --set-mss 1460
ipt_add POSTROUTING -p tcp --tcp-flags SYN,RST SYN     -j TCPMSS --set-mss 1460

info "iptables TCPMSS clamp (MSS=1460) applied on PREROUTING/OUTPUT/FORWARD/POSTROUTING."

# Strip TCP timestamp option from outbound SYN/SYN-ACK packets.
# Requires xt_TCPOPTSTRIP kernel module (available in most Ubuntu 22.04 kernels).
if modprobe xt_TCPOPTSTRIP 2>/dev/null; then
    # Strip timestamps from outbound packets (OUTPUT = locally initiated)
    ipt_add OUTPUT      -p tcp --syn                         -j TCPOPTSTRIP --strip-options timestamp
    ipt_add OUTPUT      -p tcp --tcp-flags SYN,ACK SYN,ACK  -j TCPOPTSTRIP --strip-options timestamp
    # Strip timestamps from upstream SYN-ACK before kernel processes them (PREROUTING)
    ipt_add PREROUTING  -p tcp --tcp-flags SYN,ACK SYN,ACK  -j TCPOPTSTRIP --strip-options timestamp
    # Strip timestamps on forwarded/NATted traffic
    ipt_add POSTROUTING -p tcp --syn                         -j TCPOPTSTRIP --strip-options timestamp
    ipt_add POSTROUTING -p tcp --tcp-flags SYN,ACK SYN,ACK  -j TCPOPTSTRIP --strip-options timestamp
    info "TCP timestamp option stripped on PREROUTING/OUTPUT/POSTROUTING."
else
    warn "xt_TCPOPTSTRIP not available – timestamps already disabled via sysctl (net.ipv4.tcp_timestamps=0)."
fi

# ─── 4. Persist iptables rules across reboots ─────────────────────────────────
if command -v iptables-save &>/dev/null; then
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
    info "iptables rules saved to /etc/iptables/rules.v4"

    # Ensure iptables-persistent restores on boot (if installed)
    if systemctl is-enabled netfilter-persistent &>/dev/null 2>&1; then
        systemctl restart netfilter-persistent
    fi
fi

# ─── 5. Persist MTU via /etc/network/interfaces or netplan ───────────────────
# (done via ip command above; for full persistence add to netplan if present)
if ls /etc/netplan/*.yaml &>/dev/null 2>&1; then
    warn "Netplan detected. MTU change is live now but not written to netplan."
    warn "To persist MTU, add 'mtu: 1500' to your netplan interface config."
fi

echo ""
info "TCP stack tuning complete. Run ./verify.sh to confirm all settings."
