#!/bin/bash

# Wait Agent Installer — used by admin panel's one-click install

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

RELEASE_REPO_URL="${WAIT_AGENT_RELEASE_REPO_URL:-https://github.com/nimeng1222/wait-release/releases}"

log_info()  { echo -e "${NC}$1"; }
log_ok()    { echo -e "${GREEN}  ✓  $1${NC}"; }
log_err()   { echo -e "${RED}  ✗  $1${NC}"; }
log_step()  { echo -e "${CYAN}▸  ${NC}$1"; }

# Parse arguments
ENDPOINT=""
TOKEN=""
INSTALL_DIR="/opt/wait"
SERVICE_NAME="wait-agent"

while [[ $# -gt 0 ]]; do
    case $1 in
        --endpoint) ENDPOINT="$2"; shift 2 ;;
        --token)    TOKEN="$2";    shift 2 ;;
        --install-dir)           INSTALL_DIR="$2";     shift 2 ;;
        --install-service-name)  SERVICE_NAME="$2";    shift 2 ;;
        *) shift ;;
    esac
done

if [ -z "$ENDPOINT" ] || [ -z "$TOKEN" ]; then
    log_err "用法: $0 --endpoint <URL> --token <TOKEN>"
    exit 1
fi

# Detect OS and arch
os_type=$(uname -s)
case $os_type in
    Linux)   os_name="linux" ;;
    *)       log_err "仅支持 Linux"; exit 1 ;;
esac

arch=$(uname -m)
case $arch in
    x86_64)  arch="amd64" ;;
    aarch64) arch="arm64" ;;
    *)       log_err "不支持的架构: $arch"; exit 1 ;;
esac

log_step "检测到系统: $os_name / $arch"

# Download binary
BINARY_NAME="wait-agent-${os_name}-${arch}"
DOWNLOAD_URL="${RELEASE_REPO_URL}/latest/download/${BINARY_NAME}"

mkdir -p "$INSTALL_DIR"
AGENT_PATH="$INSTALL_DIR/agent"

log_step "下载 agent 二进制..."
log_info "  URL: $DOWNLOAD_URL"

if ! curl -fL -o "$AGENT_PATH" "$DOWNLOAD_URL"; then
    log_err "下载失败"
    exit 1
fi
chmod +x "$AGENT_PATH"
log_ok "下载完成"

# systemd service
if ! command -v systemctl >/dev/null 2>&1; then
    log_err "需要 systemd，当前系统不支持"
    exit 1
fi

SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Wait Agent Service
After=network.target

[Service]
Type=simple
ExecStart=${AGENT_PATH} --endpoint "${ENDPOINT}" --token "${TOKEN}"
WorkingDirectory=${INSTALL_DIR}
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}.service"
systemctl start "${SERVICE_NAME}.service"

if systemctl is-active --quiet "${SERVICE_NAME}.service"; then
    echo
    log_ok "安装完成！"
    log_info "  服务: systemctl status $SERVICE_NAME"
    log_info "  日志: journalctl -u $SERVICE_NAME -f"
    echo
else
    log_err "服务启动失败"
    journalctl -u "${SERVICE_NAME}" --no-pager -n 20
    exit 1
fi
