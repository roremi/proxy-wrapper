#!/usr/bin/env bash
# install.sh – One-shot installer for proxy-wrapper on Ubuntu 22.04 LTS
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[+]${NC} $*"; }
step()  { echo -e "${CYAN}[→]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
fatal() { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }

[[ $EUID -ne 0 ]] && fatal "Run as root: sudo bash install.sh"

INSTALL_DIR="/opt/proxy-wrapper"
SERVICE_NAME="proxy-wrapper"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
NODE_MIN_VERSION=18

# ─── 1. System packages ───────────────────────────────────────────────────────
step "Updating package index ..."
apt-get update -y -qq

step "Installing base dependencies ..."
apt-get install -y -qq curl ca-certificates iptables iptables-persistent \
    iproute2 procps net-tools

# ─── 2. Node.js ≥ 18 ─────────────────────────────────────────────────────────
if command -v node &>/dev/null; then
    NODE_VER=$(node --version | sed 's/v//' | cut -d. -f1)
    if (( NODE_VER < NODE_MIN_VERSION )); then
        warn "Node.js ${NODE_VER} is too old (need ≥ ${NODE_MIN_VERSION}). Upgrading ..."
        INSTALL_NODE=1
    else
        info "Node.js $(node --version) already installed."
        INSTALL_NODE=0
    fi
else
    INSTALL_NODE=1
fi

if (( INSTALL_NODE )); then
    step "Installing Node.js 20 LTS via NodeSource ..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - > /dev/null
    apt-get install -y -qq nodejs
    info "Node.js $(node --version) installed."
fi

# ─── 3. Copy project files ────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

step "Installing proxy-wrapper to ${INSTALL_DIR} ..."
mkdir -p "${INSTALL_DIR}"

rsync -a --exclude='.git' --exclude='node_modules' \
    "${SCRIPT_DIR}/" "${INSTALL_DIR}/" 2>/dev/null \
    || cp -r "${SCRIPT_DIR}/." "${INSTALL_DIR}/"

# ─── 4. npm install ───────────────────────────────────────────────────────────
step "Installing npm dependencies ..."
cd "${INSTALL_DIR}"
npm install --omit=dev --silent
info "npm dependencies installed."

# ─── 5. .env configuration ───────────────────────────────────────────────────
if [[ ! -f "${INSTALL_DIR}/.env" ]]; then
    cp "${INSTALL_DIR}/.env.example" "${INSTALL_DIR}/.env"
    chmod 600 "${INSTALL_DIR}/.env"
    warn "Created ${INSTALL_DIR}/.env from template."
    warn "IMPORTANT: Edit .env with your upstream proxy credentials before starting the service."
else
    info ".env already exists – keeping existing configuration."
fi

# ─── 6. Dedicated system user ────────────────────────────────────────────────
if ! id -u proxywrapper &>/dev/null; then
    step "Creating system user 'proxywrapper' ..."
    useradd --system --no-create-home --shell /usr/sbin/nologin proxywrapper
fi
chown -R proxywrapper:proxywrapper "${INSTALL_DIR}"
chmod 700 "${INSTALL_DIR}"
chmod 600 "${INSTALL_DIR}/.env"

# ─── 7. TCP stack tuning ──────────────────────────────────────────────────────
step "Applying TCP stack tuning ..."
bash "${INSTALL_DIR}/setup-tcp.sh"

# ─── 8. systemd service ───────────────────────────────────────────────────────
step "Installing systemd service ..."
cp "${INSTALL_DIR}/proxy.service" "${SERVICE_FILE}"
# Patch WorkingDirectory and ExecStart to use actual install path
sed -i "s|/opt/proxy-wrapper|${INSTALL_DIR}|g" "${SERVICE_FILE}"
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"
info "Service '${SERVICE_NAME}' enabled (will auto-start on boot)."

# ─── 9. Verify TCP stack ──────────────────────────────────────────────────────
step "Verifying TCP stack settings ..."
bash "${INSTALL_DIR}/verify.sh" --no-proxy-test

# ─── 10. Done ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║          Installation complete!                      ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo "  Next steps:"
echo "  1. Edit upstream proxy credentials:"
echo "       nano ${INSTALL_DIR}/.env"
echo ""
echo "  2. Start the service:"
echo "       systemctl start ${SERVICE_NAME}"
echo ""
echo "  3. Check service status:"
echo "       systemctl status ${SERVICE_NAME}"
echo "       journalctl -u ${SERVICE_NAME} -f"
echo ""
echo "  4. Verify everything works:"
echo "       bash ${INSTALL_DIR}/verify.sh"
