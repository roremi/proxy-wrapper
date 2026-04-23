#!/usr/bin/env bash
# verify.sh – Print current TCP/IP stack parameters and optionally test the proxy
set -euo pipefail

INSTALL_DIR="/opt/proxy-wrapper"
ENV_FILE="${INSTALL_DIR}/.env"
NO_PROXY_TEST=0

for arg in "$@"; do
    [[ "$arg" == "--no-proxy-test" ]] && NO_PROXY_TEST=1
done

# Colour helpers
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

ok()   { echo -e "  ${GREEN}✔${NC}  $*"; }
fail() { echo -e "  ${RED}✘${NC}  $*"; }
info() { echo -e "  ${CYAN}•${NC}  $*"; }

header() {
    echo ""
    echo -e "${BOLD}${CYAN}══════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  $*${NC}"
    echo -e "${BOLD}${CYAN}══════════════════════════════════════════════${NC}"
}

# ─── 1. TTL ──────────────────────────────────────────────────────────────────
header "TTL"
TTL=$(sysctl -n net.ipv4.ip_default_ttl 2>/dev/null || echo "unknown")
if [[ "$TTL" == "128" ]]; then
    ok "net.ipv4.ip_default_ttl = ${TTL}  (Windows 10 default)"
else
    fail "net.ipv4.ip_default_ttl = ${TTL}  (expected 128 for Windows-like)"
fi

# ─── 2. TCP Timestamps ───────────────────────────────────────────────────────
header "TCP Timestamps"
TSTAMP=$(sysctl -n net.ipv4.tcp_timestamps 2>/dev/null || echo "unknown")
if [[ "$TSTAMP" == "0" ]]; then
    ok "net.ipv4.tcp_timestamps = 0  (disabled – Windows 10 default)"
else
    fail "net.ipv4.tcp_timestamps = ${TSTAMP}  (expected 0)"
fi

# ─── 3. SACK ─────────────────────────────────────────────────────────────────
header "TCP SACK"
SACK=$(sysctl -n net.ipv4.tcp_sack 2>/dev/null || echo "unknown")
if [[ "$SACK" == "1" ]]; then
    ok "net.ipv4.tcp_sack = 1  (enabled)"
else
    fail "net.ipv4.tcp_sack = ${SACK}  (expected 1)"
fi

# ─── 4. TCP Window Scaling ───────────────────────────────────────────────────
header "TCP Window Scaling"
WS=$(sysctl -n net.ipv4.tcp_window_scaling 2>/dev/null || echo "unknown")
if [[ "$WS" == "1" ]]; then
    ok "net.ipv4.tcp_window_scaling = 1"
else
    fail "net.ipv4.tcp_window_scaling = ${WS}  (expected 1)"
fi

# ─── 5. TCP ECN ──────────────────────────────────────────────────────────────
header "TCP ECN"
ECN=$(sysctl -n net.ipv4.tcp_ecn 2>/dev/null || echo "unknown")
if [[ "$ECN" == "0" ]]; then
    ok "net.ipv4.tcp_ecn = 0  (disabled – Windows 10 default)"
else
    fail "net.ipv4.tcp_ecn = ${ECN}  (expected 0)"
fi

# ─── 6. Buffer sizes ─────────────────────────────────────────────────────────
header "Socket Buffer Sizes"
info "net.core.rmem_default = $(sysctl -n net.core.rmem_default 2>/dev/null)"
info "net.core.wmem_default = $(sysctl -n net.core.wmem_default 2>/dev/null)"
info "net.ipv4.tcp_rmem     = $(sysctl -n net.ipv4.tcp_rmem 2>/dev/null)"
info "net.ipv4.tcp_wmem     = $(sysctl -n net.ipv4.tcp_wmem 2>/dev/null)"

# ─── 7. MTU ──────────────────────────────────────────────────────────────────
header "MTU (non-loopback interfaces)"
while IFS= read -r iface; do
    MTU=$(ip link show "$iface" 2>/dev/null \
          | awk '/mtu/{for(i=1;i<=NF;i++) if($i=="mtu") print $(i+1)}')
    if [[ "$MTU" == "1500" ]]; then
        ok "${iface}: MTU = ${MTU}"
    else
        fail "${iface}: MTU = ${MTU}  (expected 1500)"
    fi
done < <(ip -o link show | awk -F': ' '{print $2}' | cut -d@ -f1 | grep -v '^lo$')

# ─── 8. iptables TCPMSS ──────────────────────────────────────────────────────
header "iptables mangle rules"
if iptables -t mangle -L POSTROUTING -n --line-numbers 2>/dev/null \
        | grep -q "TCPMSS.*set-mss 1460"; then
    ok "TCPMSS clamp rule found (MSS=1460)"
else
    fail "TCPMSS clamp rule NOT found – run setup-tcp.sh"
fi

if iptables -t mangle -L POSTROUTING -n 2>/dev/null \
        | grep -q "TCPOPTSTRIP.*timestamp" 2>/dev/null; then
    ok "TCPOPTSTRIP timestamp rule found"
else
    info "TCPOPTSTRIP not active (relying on sysctl tcp_timestamps=0)"
fi

echo ""
echo -e "  ${YELLOW}Full mangle POSTROUTING chain:${NC}"
iptables -t mangle -L POSTROUTING -n -v 2>/dev/null \
    | sed 's/^/    /' || true

# ─── 9. Proxy service status ─────────────────────────────────────────────────
header "Proxy Service"
if systemctl is-active --quiet proxy-wrapper 2>/dev/null; then
    ok "proxy-wrapper.service is RUNNING"
    LISTEN=$(ss -tlnp 2>/dev/null | grep node || true)
    [[ -n "$LISTEN" ]] && info "Listening socket: $LISTEN"
else
    fail "proxy-wrapper.service is NOT running"
    info "Start with: systemctl start proxy-wrapper"
fi

# ─── 10. Proxy connectivity test ─────────────────────────────────────────────
if [[ $NO_PROXY_TEST -eq 1 ]]; then
    echo ""
    info "Skipping proxy connectivity test (--no-proxy-test)"
    echo ""
    exit 0
fi

header "Proxy Connectivity Test"

# Read LISTEN_PORT from .env if available
PROXY_PORT=1080
if [[ -f "$ENV_FILE" ]]; then
    P=$(grep -E '^LISTEN_PORT=' "$ENV_FILE" | cut -d= -f2 | tr -d ' ')
    [[ -n "$P" ]] && PROXY_PORT="$P"
fi
info "Testing SOCKS5 proxy at 127.0.0.1:${PROXY_PORT} ..."

if ! command -v curl &>/dev/null; then
    warn "curl not found – skipping connectivity test"
    exit 0
fi

RESULT=$(curl --silent --max-time 15 \
              --proxy "socks5h://127.0.0.1:${PROXY_PORT}" \
              "https://ifconfig.me/ip" 2>&1 || true)

if [[ "$RESULT" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    ok "Proxy is working. Exit IP = ${GREEN}${RESULT}${NC}"
else
    fail "Proxy test failed. Response: ${RESULT}"
    info "Is the service running? Is .env configured correctly?"
fi

echo ""
