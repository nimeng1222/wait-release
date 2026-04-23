#!/bin/bash

# Wait Agent Installer — used by admin panel's one-click install

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

RELEASE_REPO_URL="${WAIT_AGENT_RELEASE_REPO_URL:-https://github.com/nimeng1222/wait-release/releases}"
SKIP_CHECKSUM_VERIFY="${WAIT_AGENT_SKIP_CHECKSUM:-0}"

log_info()  { echo -e "${NC}$1"; }
log_ok()    { echo -e "${GREEN}  ✓  $1${NC}"; }
log_err()   { echo -e "${RED}  ✗  $1${NC}"; }
log_step()  { echo -e "${CYAN}▸  ${NC}$1"; }

ensure_agent_account() {
    if id -u "$AGENT_USER" >/dev/null 2>&1; then
        return 0
    fi

    if command -v useradd >/dev/null 2>&1; then
        useradd --system --home-dir "$INSTALL_DIR" --shell /usr/sbin/nologin --user-group "$AGENT_USER" 2>/dev/null \
            || useradd --system --home "$INSTALL_DIR" --shell /bin/false "$AGENT_USER" 2>/dev/null \
            || true
    elif command -v adduser >/dev/null 2>&1; then
        adduser --system --home "$INSTALL_DIR" --shell /usr/sbin/nologin "$AGENT_USER" 2>/dev/null \
            || adduser -S -D -H -h "$INSTALL_DIR" "$AGENT_USER" 2>/dev/null \
            || true
    fi

    id -u "$AGENT_USER" >/dev/null 2>&1
}

select_runtime_identity() {
    RUNTIME_USER="root"
    RUNTIME_GROUP="root"
    if ensure_agent_account; then
        RUNTIME_USER="$AGENT_USER"
        RUNTIME_GROUP="$(id -gn "$AGENT_USER" 2>/dev/null || printf '%s' "$AGENT_USER")"
        return
    fi
    log_err "无法创建专用服务账号，将继续以 root 运行"
}

sha256_file() {
    local file_path="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file_path" | awk '{print $1}'
        return
    fi
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file_path" | awk '{print $1}'
        return
    fi
    if command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$file_path" | awk '{print $NF}'
        return
    fi
    log_err "未找到 SHA-256 计算工具（sha256sum/shasum/openssl）"
    exit 1
}

build_release_asset_url() {
    local asset_name="$1"
    printf '%s/latest/download/%s\n' "$RELEASE_REPO_URL" "$asset_name"
}

download_release_asset() {
    local url="$1"
    local output_path="$2"
    curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fL -o "$output_path" "$url"
}

download_release_checksum_sidecar() {
    local binary_name="$1"
    local checksum_url
    local checksum_path
    checksum_url="$(build_release_asset_url "${binary_name}.sha256")"
    checksum_path="$(mktemp)"
    if ! download_release_asset "$checksum_url" "$checksum_path"; then
        rm -f "$checksum_path"
        return 1
    fi
    printf '%s\n' "$checksum_path"
}

extract_expected_checksum() {
    local checksum_path="$1"
    awk 'NF >= 1 {print $1; exit}' "$checksum_path"
}

verify_downloaded_release_file() {
    local file_path="$1"
    local file_name="$2"

    if [ "$SKIP_CHECKSUM_VERIFY" = "1" ]; then
        log_err "高危：WAIT_AGENT_SKIP_CHECKSUM=1，已跳过二进制完整性校验"
        return 0
    fi

    local checksum_path
    local expected_hash
    local actual_hash

    if ! checksum_path="$(download_release_checksum_sidecar "$file_name")"; then
        log_err "无法下载 ${file_name}.sha256，拒绝安装未校验二进制（可通过 WAIT_AGENT_SKIP_CHECKSUM=1 显式跳过）"
        return 1
    fi
    expected_hash="$(extract_expected_checksum "$checksum_path")"
    rm -f "$checksum_path"

    if [ -z "$expected_hash" ]; then
        log_err "${file_name}.sha256 内容无效"
        return 1
    fi

    actual_hash="$(sha256_file "$file_path")"
    if [ "$actual_hash" != "$expected_hash" ]; then
        log_err "校验失败：${file_name} 期望 ${expected_hash}，实际 ${actual_hash}"
        return 1
    fi

    log_ok "SHA-256 校验通过"
}

# Parse arguments
ENDPOINT=""
TOKEN=""
INSTALL_DIR="/opt/wait"
SERVICE_NAME="wait-agent"
AGENT_USER="wait-agent"
RUNTIME_USER="root"
RUNTIME_GROUP="root"

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

select_runtime_identity

log_step "下载 agent 二进制..."
log_info "  URL: $DOWNLOAD_URL"

if ! curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fL -o "$AGENT_PATH" "$DOWNLOAD_URL"; then
    log_err "下载失败"
    exit 1
fi
if ! verify_downloaded_release_file "$AGENT_PATH" "$BINARY_NAME"; then
    rm -f "$AGENT_PATH"
    exit 1
fi
chmod +x "$AGENT_PATH"
if [ "$RUNTIME_USER" != "root" ]; then
    chown -R "$RUNTIME_USER:$RUNTIME_GROUP" "$INSTALL_DIR"
fi
log_ok "下载完成"

# systemd service
if ! command -v systemctl >/dev/null 2>&1; then
    log_err "需要 systemd，当前系统不支持"
    exit 1
fi

SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
ENV_FILE="${INSTALL_DIR}/${SERVICE_NAME}.env"
umask 077
cat > "$ENV_FILE" << EOF
AGENT_ENDPOINT=${ENDPOINT}
AGENT_TOKEN=${TOKEN}
EOF
chmod 600 "$ENV_FILE"

cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Wait Agent Service
After=network.target

[Service]
Type=simple
EnvironmentFile=-${ENV_FILE}
ExecStart=${AGENT_PATH}
WorkingDirectory=${INSTALL_DIR}
Restart=always
User=${RUNTIME_USER}
Group=${RUNTIME_GROUP}
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ProtectControlGroups=true
ProtectKernelTunables=true
ProtectKernelModules=true
RestrictSUIDSGID=true
LockPersonality=true
ReadWritePaths=${INSTALL_DIR}

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
