#!/bin/bash

# ============================================================
#  Wait Monitor — Installer & Manager
# ============================================================

# ── Color definitions ──────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Global variables ───────────────────────────────────────
INSTALL_DIR="/opt/wait-monitor"
DATA_DIR="/opt/wait-monitor"
SERVICE_NAME="wait-monitor"
BINARY_PATH="$INSTALL_DIR/wait-monitor"
DEFAULT_PORT="25774"
LISTEN_PORT=""
REPO_OWNER="nimeng1222"
REPO_NAME="wait-monitor"
DEFAULT_RELEASE_REPO_URL="https://github.com/nimeng1222/wait-release/releases"
RELEASE_REPO_URL="${WAIT_MAIN_RELEASE_REPO_URL:-$DEFAULT_RELEASE_REPO_URL}"
RELEASE_VERSION="${WAIT_MAIN_RELEASE_VERSION:-}"
SERVICE_USER="wait-monitor"
SERVICE_GROUP="wait-monitor"
RUNTIME_USER="root"
RUNTIME_GROUP="root"
SERVICE_DATA_DIR="${INSTALL_DIR}/data"

if [ -n "$RELEASE_VERSION" ]; then
    RELEASE_LABEL="$RELEASE_VERSION"
else
    RELEASE_LABEL="latest"
fi

# ── Logging helpers ────────────────────────────────────────
info()    { echo -e "${NC}$1${NC}"; }
ok()      { echo -e "${GREEN}  ✓  $1${NC}"; }
warn()    { echo -e "${YELLOW}  ⚠  $1${NC}"; }
err()     { echo -e "${RED}  ✗  $1${NC}"; }
step()    { echo -e "${CYAN}${BOLD}▸${NC} ${BOLD}$1${NC}"; }
divider() { echo -e "${CYAN}──────────────────────────────────────────────────────${NC}"; }

# ── Spinner for long-running tasks ─────────────────────────
spinner() {
    local pid=$1
    local msg=$2
    local spin='⣾⣽⣻⢿⡿⣟⣯⣷'
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        i=$(( (i+1) % 8 ))
        printf "\r  ${CYAN}${spin:$i:1}${NC}  $msg"
        sleep 0.1
    done
    wait "$pid"
    local ret=$?
    printf "\r"
    return $ret
}

# ── Banner ─────────────────────────────────────────────────
show_banner() {
    clear
    echo
    echo -e "${CYAN}${BOLD}"
    echo "   ██╗    ██╗███████╗██╗      ██████╗ ██████╗ ██████╗ ███████╗██████╗ "
    echo "   ██║    ██║██╔════╝██║     ██╔═══██╗██╔══██╗██╔══██╗██╔════╝██╔══██╗"
    echo "   ██║ █╗ ██║█████╗  ██║     ██║   ██║██████╔╝██║  ██║█████╗  ██████╔╝"
    echo "   ██║███╗██║██╔══╝  ██║     ██║   ██║██╔═══╝ ██║  ██║██╔══╝  ██╔══██╗"
    echo "   ╚███╔███╔╝███████╗███████╗╚██████╔╝██║     ██████╔╝███████╗██║  ██║"
    echo "    ╚══╝╚══╝ ╚══════╝╚══════╝ ╚═════╝ ╚═╝     ╚═════╝ ╚══════╝╚═╝  ╚═╝"
    echo
    echo -e "   ${GREEN}${BOLD}Infrastructure Monitor  •  ${RELEASE_LABEL}${NC}"
    echo
    divider
    echo
}

build_download_url() {
    local file_name="$1"
    if [ -n "$RELEASE_VERSION" ]; then
        echo "${RELEASE_REPO_URL}/download/${RELEASE_VERSION}/${file_name}"
    else
        echo "${RELEASE_REPO_URL}/latest/download/${file_name}"
    fi
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
    err "未找到 sha256 校验工具"
    exit 1
}

copy_backup_verified() {
    local source_path="$1"
    local backup_path="$2"

    rm -f "$backup_path"
    cp "$source_path" "$backup_path"
    if [ ! -s "$backup_path" ]; then
        return 1
    fi

    local source_hash
    local backup_hash
    source_hash="$(sha256_file "$source_path")"
    backup_hash="$(sha256_file "$backup_path")"
    if [ "$source_hash" != "$backup_hash" ]; then
        return 1
    fi

    chmod +x "$backup_path"
    printf '%s\n' "$source_hash"
}

restore_backup_verified() {
    local backup_path="$1"
    local destination_path="$2"
    local expected_hash="$3"

    cp "$backup_path" "$destination_path"
    chmod +x "$destination_path"
    if [ -n "$expected_hash" ] && [ "$(sha256_file "$destination_path")" != "$expected_hash" ]; then
        return 1
    fi
}

verify_binary_compatible() {
    local binary_path="$1"
    local verify_output
    verify_output=$("$binary_path" server -l 0.0.0.0:1 2>&1 | head -5 || true)
    if echo "$verify_output" | grep -qi "CGO_ENABLED\|go-sqlite3\|requires cgo\|sqlite3.*cgo"; then
        return 1
    fi
}

ensure_service_account() {
    if id -u "$SERVICE_USER" >/dev/null 2>&1; then
        return 0
    fi

    if command -v useradd >/dev/null 2>&1; then
        useradd --system --home-dir "$INSTALL_DIR" --shell /usr/sbin/nologin --user-group "$SERVICE_USER" 2>/dev/null \
            || useradd --system --home "$INSTALL_DIR" --shell /bin/false "$SERVICE_USER" 2>/dev/null \
            || true
    elif command -v adduser >/dev/null 2>&1; then
        adduser --system --home "$INSTALL_DIR" --shell /usr/sbin/nologin "$SERVICE_USER" 2>/dev/null \
            || adduser -S -D -H -h "$INSTALL_DIR" "$SERVICE_USER" 2>/dev/null \
            || true
    fi

    id -u "$SERVICE_USER" >/dev/null 2>&1
}

select_runtime_identity() {
    local port="$1"
    RUNTIME_USER="root"
    RUNTIME_GROUP="root"

    if ! ensure_service_account; then
        warn "无法创建专用服务账号，将继续以 root 运行"
        return
    fi

    if [ "$port" -lt 1024 ] && ! command -v setcap >/dev/null 2>&1; then
        warn "监听端口低于 1024 且未检测到 setcap，将继续以 root 运行"
        return
    fi

    RUNTIME_USER="$SERVICE_USER"
    RUNTIME_GROUP="$SERVICE_GROUP"
}

prepare_runtime_paths() {
    mkdir -p "$INSTALL_DIR" "$SERVICE_DATA_DIR"
    chmod 755 "$INSTALL_DIR"
    if [ "$RUNTIME_USER" != "root" ]; then
        chown -R "$RUNTIME_USER:$RUNTIME_GROUP" "$SERVICE_DATA_DIR"
        chmod 750 "$SERVICE_DATA_DIR"
    fi
}

current_service_file() {
    echo "/etc/systemd/system/${SERVICE_NAME}.service"
}

current_service_user() {
    local service_file
    service_file="$(current_service_file)"
    if [ ! -f "$service_file" ]; then
        echo "root"
        return
    fi
    sed -n 's/^User=//p' "$service_file" | head -n 1
}

current_service_port() {
    local service_file
    service_file="$(current_service_file)"
    if [ ! -f "$service_file" ]; then
        echo "$DEFAULT_PORT"
        return
    fi
    sed -n 's/^ExecStart=.*0\.0\.0\.0:\([0-9][0-9]*\).*$/\1/p' "$service_file" | head -n 1
}

configure_binary_runtime_privileges() {
    local port="$1"
    if command -v setcap >/dev/null 2>&1; then
        setcap -r "$BINARY_PATH" 2>/dev/null || true
    fi

    if [ "$RUNTIME_USER" != "root" ] && [ "$port" -lt 1024 ]; then
        if ! command -v setcap >/dev/null 2>&1; then
            err "端口低于 1024 时需要 setcap 支持非 root 绑定"
            return 1
        fi
        setcap cap_net_bind_service=+ep "$BINARY_PATH"
    fi
}

# ── Root & systemd checks ──────────────────────────────────
check_root() {
    if [ "$EUID" -ne 0 ]; then
        err "请使用 root 权限运行此脚本"
        echo
        exit 1
    fi
}

check_systemd() {
    command -v systemctl >/dev/null 2>&1
}

# ── Architecture detection ─────────────────────────────────
detect_arch() {
    local arch=$(uname -m)
    case $arch in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        i386|i686) echo "386" ;;
        riscv64) echo "riscv64" ;;
        *) err "不支持的架构: $arch"; exit 1 ;;
    esac
}

# ── Install state ──────────────────────────────────────────
is_installed() {
    [ -f "$BINARY_PATH" ]
}

# ── Dependencies ───────────────────────────────────────────
install_dependencies() {
    if command -v curl >/dev/null 2>&1; then
        return
    fi

    step "安装 curl 依赖..."
    if command -v apt >/dev/null 2>&1; then
        apt update -qq && apt install -y curl >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl >/dev/null 2>&1
    elif command -v apk >/dev/null 2>&1; then
        apk add curl >/dev/null 2>&1
    else
        err "未找到支持的包管理器 (apt/yum/apk)"
        exit 1
    fi

    if command -v curl >/dev/null 2>&1; then
        ok "curl 安装成功"
    else
        err "curl 安装失败"
        exit 1
    fi
}

# ── Install helpers ────────────────────────────────────────
install_default() {
    LISTEN_PORT="$DEFAULT_PORT"
    ok "使用默认端口: ${BOLD}$LISTEN_PORT${NC}"
    _do_install
}

install_custom() {
    echo
    while true; do
        read -p "  ${CYAN}请输入监听端口${NC} [1-65535]: " input_port
        if [[ "$input_port" =~ ^[0-9]+$ ]] && (( input_port >= 1 && input_port <= 65535 )); then
            LISTEN_PORT="$input_port"
            break
        fi
        err "端口号无效，请输入 1-65535 之间的数字"
    done
    _do_install
}

_do_install() {
    echo
    divider
    echo

    if is_installed; then
        warn "wait-monitor 已安装，要升级请使用升级选项"
        echo
        return
    fi

    install_dependencies

    local arch=$(detect_arch)
    ok "检测到架构: ${BOLD}$arch${NC}"

    step "创建目录..."
    select_runtime_identity "$LISTEN_PORT"
    mkdir -p "$INSTALL_DIR" "$DATA_DIR"
    prepare_runtime_paths
    ok "$INSTALL_DIR"

    local file_name="wait-linux-${arch}"
    local download_url
    download_url="$(build_download_url "$file_name")"

    step "下载二进制文件..."
    (curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fL# -o "$BINARY_PATH" "$download_url") 2>&1 &
    spinner $! "正在下载..."
    if [ $? -ne 0 ]; then
        echo
        err "下载失败，请确认 release 产物存在且有权限访问"
        return 1
    fi
    echo
    ok "下载完成"

    chmod +x "$BINARY_PATH"

    step "验证二进制兼容性..."
    if ! verify_binary_compatible "$BINARY_PATH"; then
        echo
        err "二进制文件不兼容：检测到 CGO_ENABLED=0 构建，go-sqlite3 无法工作"
        err "请重新下载最新 release：$RELEASE_REPO_URL/latest"
        err "如问题持续，请到 GitHub 提 issue：https://github.com/nimeng1222/wait-monitor/issues"
        return 1
    fi
    ok "二进制验证通过"
    configure_binary_runtime_privileges "$LISTEN_PORT"

    if ! check_systemd; then
        warn "未检测到 systemd，跳过服务创建"
        echo
        info "  手动运行: ${CYAN}$BINARY_PATH server -l 0.0.0.0:$LISTEN_PORT${NC}"
        echo
        ok "安装完成！"
        return
    fi

    create_systemd_service "$LISTEN_PORT"

    step "注册 systemd 服务..."
    systemctl daemon-reload
    systemctl enable ${SERVICE_NAME}.service
    systemctl start ${SERVICE_NAME}.service
    ok "服务已注册并启动"

    if systemctl is-active --quiet ${SERVICE_NAME}.service; then
        ok "wait-monitor 运行中"
        echo
        step "获取初始密码..."
        sleep 5
        local credential_file="${DATA_DIR}/data/initial-admin-credentials.json"
        local username=$(sed -n 's/.*"username":[[:space:]]*"\([^"]*\)".*/\1/p' "$credential_file" 2>/dev/null | head -n 1)
        local password=$(sed -n 's/.*"password":[[:space:]]*"\([^"]*\)".*/\1/p' "$credential_file" 2>/dev/null | head -n 1)
        if [ -z "$password" ]; then
            warn "未能读取初始凭据文件，请检查 ${credential_file}"
        fi
        show_access_info "$username" "$password" "$LISTEN_PORT" "$credential_file"
    else
        err "wait-monitor 服务启动失败"
        info "  查看日志: ${CYAN}journalctl -u ${SERVICE_NAME} -f${NC}"
        return 1
    fi
}

# ── Install entry ──────────────────────────────────────────
install_binary() {
    echo
    step "安装 wait-monitor"
    echo
    info "  ${BOLD}1)${NC}  默认安装  (端口 ${CYAN}$DEFAULT_PORT${NC})"
    info "  ${BOLD}2)${NC}  自定义端口"
    echo
    read -p "  选择 [1-2]: " choice
    echo

    case $choice in
        1) install_default ;;
        2) install_custom ;;
        *) err "无效选项"; return 1 ;;
    esac
}

# ── systemd service ────────────────────────────────────────
create_systemd_service() {
    local port="$1"
    local service_file="/etc/systemd/system/${SERVICE_NAME}.service"
    cat > "$service_file" << EOF
[Unit]
Description=Wait Monitor Service
After=network.target

[Service]
Type=simple
ExecStart=${BINARY_PATH} server -l 0.0.0.0:${port}
WorkingDirectory=${DATA_DIR}
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
ReadWritePaths=${SERVICE_DATA_DIR}

[Install]
WantedBy=multi-user.target
EOF
    ok "systemd 服务文件已创建"
}

# ── Access info ────────────────────────────────────────────
show_access_info() {
    local username=$1
    local password=$2
    local port=${3:-$DEFAULT_PORT}
    local credential_file=$4
    local ip=$(hostname -I | awk '{print $1}')

    echo
    divider
    echo
    echo -e "  ${GREEN}${BOLD}🎉 安装完成！${NC}"
    echo
    divider
    echo
    info "  ${BOLD}访问地址${NC}"
    info "    ${CYAN}http://${ip}:${port}${NC}"
    if [ -n "$password" ]; then
        echo
        info "  ${BOLD}初始登录信息${NC}  (仅显示一次)"
        info "    用户名: ${YELLOW}${BOLD}${username:-admin}${NC}"
        info "    密码: ${YELLOW}${BOLD}$password${NC}"
        if [ -n "$credential_file" ]; then
            info "    凭据文件: ${CYAN}${credential_file}${NC}"
        fi
    fi
    echo
    divider
    echo
    info "  ${BOLD}常用命令${NC}"
    info "    状态: ${CYAN}systemctl status $SERVICE_NAME${NC}"
    info "    日志: ${CYAN}journalctl -u $SERVICE_NAME -f${NC}"
    info "    重启: ${CYAN}systemctl restart $SERVICE_NAME${NC}"
    echo
}

# ── Upgrade ────────────────────────────────────────────────
upgrade_wait() {
    echo
    step "升级 wait-monitor"
    echo

    if ! is_installed; then
        err "wait-monitor 未安装，请先安装"
        return 1
    fi
    if ! check_systemd; then
        err "未检测到 systemd"
        return 1
    fi

    systemctl stop ${SERVICE_NAME}.service
    ok "服务已停止"

    local backup_path="${BINARY_PATH}.backup"
    local backup_hash
    backup_hash="$(copy_backup_verified "$BINARY_PATH" "$backup_path")" || {
        err "备份当前二进制失败，已中止升级"
        systemctl start ${SERVICE_NAME}.service
        return 1
    }
    local current_port
    local configured_user
    current_port="$(current_service_port)"
    configured_user="$(current_service_user)"
    if [ -z "$current_port" ]; then
        current_port="$DEFAULT_PORT"
    fi
    if [ -n "$configured_user" ] && [ "$configured_user" != "root" ]; then
        ensure_service_account || warn "未能确认专用服务账号存在，将保留当前服务文件配置"
        RUNTIME_USER="$configured_user"
        RUNTIME_GROUP="$configured_user"
    else
        RUNTIME_USER="root"
        RUNTIME_GROUP="root"
    fi
    prepare_runtime_paths

    local arch=$(detect_arch)
    local file_name="wait-linux-${arch}"
    local download_url
    download_url="$(build_download_url "$file_name")"

    step "下载最新版本..."
    if ! curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fL -o "$BINARY_PATH" "$download_url"; then
        err "下载失败，正在恢复"
        restore_backup_verified "$backup_path" "$BINARY_PATH" "$backup_hash" || err "恢复备份校验失败，请手动检查 ${backup_path}"
        configure_binary_runtime_privileges "$current_port" || true
        systemctl start ${SERVICE_NAME}.service
        return 1
    fi
    chmod +x "$BINARY_PATH"
    ok "下载完成"

    step "验证二进制兼容性..."
    if ! verify_binary_compatible "$BINARY_PATH"; then
        err "二进制文件不兼容，恢复备份并终止"
        restore_backup_verified "$backup_path" "$BINARY_PATH" "$backup_hash" || err "恢复备份校验失败，请手动检查 ${backup_path}"
        configure_binary_runtime_privileges "$current_port" || true
        systemctl start ${SERVICE_NAME}.service
        return 1
    fi
    ok "二进制验证通过"
    if ! configure_binary_runtime_privileges "$current_port"; then
        err "应用运行权限失败，恢复备份并终止"
        restore_backup_verified "$backup_path" "$BINARY_PATH" "$backup_hash" || err "恢复备份校验失败，请手动检查 ${backup_path}"
        configure_binary_runtime_privileges "$current_port" || true
        systemctl start ${SERVICE_NAME}.service
        return 1
    fi

    systemctl start ${SERVICE_NAME}.service
    if systemctl is-active --quiet ${SERVICE_NAME}.service; then
        ok "wait-monitor 升级成功"
        rm -f "$backup_path"
    else
        err "服务升级后未能启动"
        warn "正在回滚到备份版本..."
        restore_backup_verified "$backup_path" "$BINARY_PATH" "$backup_hash" || err "恢复备份校验失败，请手动检查 ${backup_path}"
        configure_binary_runtime_privileges "$current_port" || true
        systemctl start ${SERVICE_NAME}.service || true
        return 1
    fi
}

# ── Uninstall ──────────────────────────────────────────────
uninstall_wait() {
    echo
    step "卸载 wait-monitor"
    echo

    if ! is_installed; then
        warn "wait-monitor 未安装"
        echo
        return 0
    fi

    read -p "  ${RED}确认删除 wait-monitor？${NC} (Y/n): " confirm
    if [[ $confirm =~ ^[Nn]$ ]]; then
        info "  已取消"
        echo
        return 0
    fi

    if check_systemd; then
        systemctl stop ${SERVICE_NAME}.service >/dev/null 2>&1
        systemctl disable ${SERVICE_NAME}.service >/dev/null 2>&1
        rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
        systemctl daemon-reload
        ok "systemd 服务已移除"
    fi

    rm -f "$BINARY_PATH"
    ok "二进制文件已删除"
    rmdir "$INSTALL_DIR" 2>/dev/null || warn "数据目录 $INSTALL_DIR 不为空，已保留"

    echo
    ok "wait-monitor 卸载完成"
    info "  数据文件保留在 ${CYAN}$DATA_DIR${NC}"
    echo
}

# ── Status / Logs / Restart / Stop ─────────────────────────
show_status() {
    if ! is_installed; then err "wait-monitor 未安装"; return; fi
    if ! check_systemd; then err "未检测到 systemd"; return; fi
    step "wait-monitor 服务状态:"
    echo
    systemctl status ${SERVICE_NAME}.service --no-pager -l
}

show_logs() {
    if ! is_installed; then err "wait-monitor 未安装"; return; fi
    if ! check_systemd; then err "未检测到 systemd"; return; fi
    step "查看 wait-monitor 服务日志:"
    echo
    journalctl -u ${SERVICE_NAME} -f --no-pager
}

restart_service() {
    if ! is_installed; then err "wait-monitor 未安装"; return; fi
    if ! check_systemd; then err "未检测到 systemd"; return; fi
    step "重启 wait-monitor 服务..."
    systemctl restart ${SERVICE_NAME}.service
    if systemctl is-active --quiet ${SERVICE_NAME}.service; then
        ok "服务已重启"
    else
        err "重启失败"
    fi
}

stop_service() {
    if ! is_installed; then err "wait-monitor 未安装"; return; fi
    if ! check_systemd; then err "未检测到 systemd"; return; fi
    step "停止 wait-monitor 服务..."
    systemctl stop ${SERVICE_NAME}.service
    ok "服务已停止"
}

# ── Uninstall agent ────────────────────────────────────────
uninstall_agent() {
    echo
    step "卸载 wait-agent"
    echo

    # Detect if there are any known agent service names
    local agent_services=("wait-agent" "wait_monitor_agent")

    local found_any=false
    if check_systemd; then
        for svc in "${agent_services[@]}"; do
            if systemctl list-unit-files 2>/dev/null | grep -q "${svc}.service"; then
                found_any=true
                step "停止并移除 systemd 服务: $svc"
                systemctl stop "${svc}.service" 2>/dev/null
                systemctl disable "${svc}.service" 2>/dev/null
                rm -f "/etc/systemd/system/${svc}.service"
                ok "服务已移除: $svc"
            fi
        done
        systemctl daemon-reload
    fi

    # Check for OpenRC services
    for svc in "${agent_services[@]}"; do
        if [ -f "/etc/init.d/${svc}" ]; then
            found_any=true
            rc-service "${svc}" stop 2>/dev/null
            rc-update del "${svc}" default 2>/dev/null
            rm -f "/etc/init.d/${svc}"
            ok "服务已移除: $svc (OpenRC)"
        fi
    done

    # Remove common install directories
    local agent_dirs=("/opt/wait" "/opt/wait-agent" "/usr/local/wait" "$HOME/.wait")
    for dir in "${agent_dirs[@]}"; do
        if [ -d "$dir" ] && [ -f "$dir/agent" ]; then
            found_any=true
            rm -rf "$dir"
            ok "目录已删除: $dir"
        fi
    done

    # macOS launchd
    if [ "$(uname -s)" = "Darwin" ]; then
        local plists=(
            "/Library/LaunchDaemons/com.wait.wait-agent.plist"
            "$HOME/Library/LaunchAgents/com.wait.wait-agent.plist"
        )
        for plist in "${plists[@]}"; do
            if [ -f "$plist" ]; then
                found_any=true
                launchctl bootout system "$plist" 2>/dev/null || true
                launchctl bootout gui/$(id -u) "$plist" 2>/dev/null || true
                rm -f "$plist"
                ok "launchd 服务已移除: $plist"
            fi
        done
    fi

    if [ "$found_any" = true ]; then
        echo
        ok "wait-agent 卸载完成"
    else
        echo
        warn "未发现已安装的 agent 痕迹"
    fi
    echo
}

# ── Main menu ──────────────────────────────────────────────
main_menu() {
    show_banner
    echo
    info "  ${BOLD}1)${NC}  安装 wait-monitor"
    info "  ${BOLD}2)${NC}  升级 wait-monitor"
    info "  ${BOLD}3)${NC}  卸载 wait-monitor"
    divider
    info "  ${BOLD}4)${NC}  查看状态"
    info "  ${BOLD}5)${NC}  查看日志"
    info "  ${BOLD}6)${NC}  重启服务"
    info "  ${BOLD}7)${NC}  停止服务"
    info "  ${BOLD}8)${NC}  卸载 agent"
    divider
    info "  ${BOLD}9)${NC}  退出"
    echo

    read -p "  选择 [1-9]: " choice
    echo

    case $choice in
        1) install_binary ;;
        2) upgrade_wait ;;
        3) uninstall_wait ;;
        4) show_status ;;
        5) show_logs ;;
        6) restart_service ;;
        7) stop_service ;;
        8) uninstall_agent ;;
        9) exit 0 ;;
        *) err "无效选项" ;;
    esac
}

# ── Entry ──────────────────────────────────────────────────
check_root
main_menu
