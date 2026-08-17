#!/usr/bin/env bash
set -Eeuo pipefail

# Wait Agent canonical installer used by the admin panel and release assets.

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

RELEASE_REPO_URL="${WAIT_AGENT_RELEASE_REPO_URL:-https://github.com/nimeng1222/wait-release/releases}"
ALLOW_UNSAFE_SKIP="${WAIT_ALLOW_UNSAFE_SKIP:-0}"
SKIP_CHECKSUM_VERIFY="${WAIT_AGENT_SKIP_CHECKSUM:-0}"
SKIP_SIGNATURE_VERIFY="${WAIT_AGENT_SKIP_SIGNATURE:-0}"
INSTALLER_TEST_MODE="${WAIT_AGENT_INSTALLER_TEST_MODE:-0}"
RELEASE_PUBKEY_PEM='-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE29f9FZIEMzvfTiaJGd6zPgpOZnIL
jndWyXnh3jM+TWNVvBarlcPGAEDxmIQAAYel8QIDJgzIs7xSKE9oLtvmmg==
-----END PUBLIC KEY-----'

SYSTEMD_DIR="/etc/systemd/system"
PROC_ROOT="/proc"
HEALTH_ATTEMPTS=15
HEALTH_POLL_INTERVAL=1
if [[ "$INSTALLER_TEST_MODE" == "1" ]]; then
    SYSTEMD_DIR="${WAIT_AGENT_INSTALLER_SYSTEMD_DIR:-$SYSTEMD_DIR}"
    PROC_ROOT="${WAIT_AGENT_INSTALLER_PROC_ROOT:-$PROC_ROOT}"
    HEALTH_ATTEMPTS="${WAIT_AGENT_INSTALLER_HEALTH_ATTEMPTS:-$HEALTH_ATTEMPTS}"
    HEALTH_POLL_INTERVAL="${WAIT_AGENT_INSTALLER_HEALTH_POLL_INTERVAL:-$HEALTH_POLL_INTERVAL}"
elif [[ "$INSTALLER_TEST_MODE" != "0" ]]; then
    printf '[ERROR] WAIT_AGENT_INSTALLER_TEST_MODE must be 0 or 1\n' >&2
    exit 1
fi

log_info()  { echo -e "${NC}$1"; }
log_ok()    { echo -e "${GREEN}  ✓  $1${NC}"; }
log_err()   { echo -e "${RED}  ✗  $1${NC}" >&2; }
log_step()  { echo -e "${CYAN}▸  ${NC}$1"; }

usage() {
    cat << EOF
用法:
  $0 --endpoint <URL> (--token <TOKEN> | --token-stdin) [--install-dir <DIR>] [--install-service-name <NAME>]
  $0 --uninstall [--install-dir <DIR>] [--install-service-name <NAME>]
EOF
}

TMP_DOWNLOAD_PATH=""
TMP_TARGET_MANIFEST_PATH=""
TMP_ENV_PATH=""
TMP_SERVICE_PATH=""
BINARY_BACKUP_PATH=""
ENV_BACKUP_PATH=""
SERVICE_BACKUP_PATH=""
AGENT_PATH=""
ENV_FILE=""
SERVICE_FILE=""
SERVICE_UNIT=""
EXPECTED_BINARY_HASH=""
HAD_BINARY=0
HAD_ENV=0
HAD_SERVICE=0
WAS_ACTIVE=0
WAS_ENABLED=0
COMMIT_STARTED=0
INSTALL_SUCCEEDED=0
ROLLBACK_DONE=0
INSTALL_DIR_CREATED=0

remove_if_set() {
    local path="$1"
    if [[ -n "$path" ]]; then
        rm -f "$path"
    fi
}

restore_file() {
    local backup_path="$1"
    local target_path="$2"
    local existed="$3"

    if [[ "$existed" == "1" ]]; then
        if [[ -z "$backup_path" || ! -f "$backup_path" ]]; then
            log_err "回滚文件缺失: $target_path"
            return 1
        fi
        mv -f "$backup_path" "$target_path"
        return
    fi
    rm -f "$target_path"
}

rollback_installation() {
    local failed=0

    if [[ "$COMMIT_STARTED" != "1" || "$ROLLBACK_DONE" == "1" ]]; then
        return 0
    fi

    log_err "安装健康检查失败，正在恢复旧版本"
    set +e
    systemctl stop "$SERVICE_UNIT" >/dev/null 2>&1
    restore_file "$BINARY_BACKUP_PATH" "$AGENT_PATH" "$HAD_BINARY" || failed=1
    restore_file "$ENV_BACKUP_PATH" "$ENV_FILE" "$HAD_ENV" || failed=1
    restore_file "$SERVICE_BACKUP_PATH" "$SERVICE_FILE" "$HAD_SERVICE" || failed=1
    systemctl daemon-reload >/dev/null 2>&1 || failed=1

    if [[ "$WAS_ENABLED" == "1" ]]; then
        systemctl enable "$SERVICE_UNIT" >/dev/null 2>&1 || failed=1
    else
        systemctl disable "$SERVICE_UNIT" >/dev/null 2>&1 || true
    fi
    if [[ "$WAS_ACTIVE" == "1" ]]; then
        systemctl restart "$SERVICE_UNIT" >/dev/null 2>&1 || failed=1
        systemctl is-active --quiet "$SERVICE_UNIT" || failed=1
    else
        systemctl stop "$SERVICE_UNIT" >/dev/null 2>&1 || true
    fi
    set -e

    if [[ "$failed" == "0" ]]; then
        ROLLBACK_DONE=1
        log_ok "已恢复安装前的二进制、配置和服务状态"
        return 0
    fi
    log_err "自动回滚未完整成功；已保留 rollback 文件供人工恢复"
    return 1
}

cleanup() {
    local status=$?
    trap - EXIT INT TERM

    if [[ "$COMMIT_STARTED" == "1" && "$INSTALL_SUCCEEDED" != "1" && "$ROLLBACK_DONE" != "1" ]]; then
        rollback_installation || status=1
    fi

    remove_if_set "$TMP_DOWNLOAD_PATH"
    remove_if_set "$TMP_TARGET_MANIFEST_PATH"
    remove_if_set "$TMP_ENV_PATH"
    remove_if_set "$TMP_SERVICE_PATH"
    if [[ "$COMMIT_STARTED" != "1" || "$INSTALL_SUCCEEDED" == "1" || "$ROLLBACK_DONE" == "1" ]]; then
        remove_if_set "$BINARY_BACKUP_PATH"
        remove_if_set "$ENV_BACKUP_PATH"
        remove_if_set "$SERVICE_BACKUP_PATH"
    fi
    if [[ "$INSTALL_DIR_CREATED" == "1" && "$INSTALL_SUCCEEDED" != "1" ]]; then
        rmdir "$INSTALL_DIR" >/dev/null 2>&1 || true
    fi

    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ "${WAIT_AGENT_SKIP_CHECKSUM:-}" == "1" ]]; then
    log_err "WAIT_AGENT_SKIP_CHECKSUM 已弃用，且只跳过 checksum。"
    if [[ "$ALLOW_UNSAFE_SKIP" != "1" ]]; then
        log_err "未同时设置 WAIT_ALLOW_UNSAFE_SKIP=1，拒绝跳过校验。"
        exit 1
    fi
fi

require_value() {
    local option="$1"
    local remaining="$2"
    if [[ "$remaining" -lt 2 ]]; then
        log_err "参数缺少值: $option"
        exit 1
    fi
}

validate_inputs() {
    if [[ "$RELEASE_REPO_URL" != https://* ]]; then
        log_err "Release 地址必须使用 HTTPS"
        return 1
    fi
    if [[ "$INSTALL_DIR" != /* || "$INSTALL_DIR" == "/" || "$INSTALL_DIR" == *$'\n'* || "$INSTALL_DIR" == *$'\r'* ]]; then
        log_err "安装目录必须是安全的绝对路径"
        return 1
    fi
    if [[ ! "$SERVICE_NAME" =~ ^[A-Za-z0-9_.@-]+$ ]]; then
        log_err "服务名只能包含字母、数字、点、下划线、@ 和连字符"
        return 1
    fi
    if [[ "$ENDPOINT" == *$'\n'* || "$ENDPOINT" == *$'\r'* || "$TOKEN" == *$'\n'* || "$TOKEN" == *$'\r'* ]]; then
        log_err "endpoint/token 不能包含换行符"
        return 1
    fi
    if [[ ! "$HEALTH_ATTEMPTS" =~ ^[1-9][0-9]*$ ]]; then
        log_err "健康检查次数无效"
        return 1
    fi
    if [[ ! "$HEALTH_POLL_INTERVAL" =~ ^([0-9]+([.][0-9]+)?)$ ]]; then
        log_err "健康检查间隔无效"
        return 1
    fi
}

preflight() {
    if [[ "$INSTALLER_TEST_MODE" != "1" && "$EUID" -ne 0 ]]; then
        log_err "请使用 root 运行安装器"
        return 1
    fi
    if [[ "$(uname -s)" != "Linux" ]]; then
        log_err "仅支持 Linux"
        return 1
    fi
    for command_name in curl openssl awk systemctl install tr cp mv sleep; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            log_err "缺少命令: $command_name"
            return 1
        fi
    done
    if ! systemctl list-units --no-legend --no-pager >/dev/null 2>&1; then
        log_err "需要正在运行的 systemd"
        return 1
    fi
    if [[ ! -d "$SYSTEMD_DIR" ]]; then
        log_err "systemd unit 目录不存在: $SYSTEMD_DIR"
        return 1
    fi
}

ensure_agent_account() {
    if [[ "$INSTALLER_TEST_MODE" == "1" ]]; then
        RUNTIME_USER="root"
        RUNTIME_GROUP="root"
        return 0
    fi
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
        if [[ "$INSTALLER_TEST_MODE" != "1" ]]; then
            RUNTIME_USER="$AGENT_USER"
            RUNTIME_GROUP="$(id -gn "$AGENT_USER" 2>/dev/null || printf '%s' "$AGENT_USER")"
        fi
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
    openssl dgst -sha256 "$file_path" | awk '{print $NF}'
}

build_release_asset_url() {
    local asset_name="$1"
    printf '%s/latest/download/%s\n' "${RELEASE_REPO_URL%/}" "$asset_name"
}

download_release_asset() {
    local url="$1"
    local output_path="$2"
    local max_bytes="${3:-268435456}"
    curl --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --fail --location --silent --show-error \
        --connect-timeout 10 --max-time 180 --max-filesize "$max_bytes" \
        --output "$output_path" "$url"
}

download_release_checksum_sidecar() {
    local binary_name="$1"
    local checksum_path
    checksum_path="$(mktemp)"
    if ! download_release_asset "$(build_release_asset_url "${binary_name}.sha256")" "$checksum_path" 4096; then
        rm -f "$checksum_path"
        return 1
    fi
    printf '%s\n' "$checksum_path"
}

download_release_signature_sidecar() {
    local binary_name="$1"
    local signature_path
    signature_path="$(mktemp)"
    if ! download_release_asset "$(build_release_asset_url "${binary_name}.sig")" "$signature_path" 65536; then
        rm -f "$signature_path"
        return 1
    fi
    printf '%s\n' "$signature_path"
}

verify_release_signature() {
    local file_path="$1"
    local file_name="$2"
    local signature_path public_key_path

    if ! signature_path="$(download_release_signature_sidecar "$file_name")"; then
        log_err "无法下载 ${file_name}.sig，拒绝安装未签名二进制"
        return 1
    fi
    public_key_path="$(mktemp)"
    printf '%s\n' "$RELEASE_PUBKEY_PEM" > "$public_key_path"
    if ! openssl dgst -sha256 -verify "$public_key_path" -signature "$signature_path" "$file_path" >/dev/null 2>&1; then
        rm -f "$signature_path" "$public_key_path"
        log_err "签名校验失败: ${file_name}"
        return 1
    fi
    rm -f "$signature_path" "$public_key_path"
    log_ok "ECDSA 签名校验通过"
}

select_release_binary_from_manifest() {
    local target_os="$1"
    local target_arch="$2"

    awk -F '\t' -v target_os="$target_os" -v target_arch="$target_arch" '
        BEGIN {
            expected_header = "schema\tos\tarch\tfilename\tci\tpublish\tinstaller\tself_update"
        }
        NR == 1 {
            if ($0 != expected_header) {
                print "invalid target manifest header" > "/dev/stderr"
                invalid = 1
                exit
            }
            next
        }
        {
            if (index($0, "\r") != 0 || NF != 8) {
                print "invalid field count in target manifest row " NR > "/dev/stderr"
                invalid = 1
                exit
            }
            if ($1 != "wait-agent-targets/v1" || $2 !~ /^[a-z0-9]+$/ ||
                $3 !~ /^[a-z0-9]+$/ || $4 !~ /^[A-Za-z0-9._-]+$/) {
                print "invalid target manifest row " NR > "/dev/stderr"
                invalid = 1
                exit
            }
            if (($5 != "true" && $5 != "false") ||
                ($6 != "true" && $6 != "false") ||
                ($8 != "true" && $8 != "false") ||
                ($7 != "none" && $7 != "systemd" && $7 != "windows-nssm")) {
                print "invalid target flags in manifest row " NR > "/dev/stderr"
                invalid = 1
                exit
            }
            key = $2 "/" $3
            if (seen_target[key]++ || seen_filename[$4]++) {
                print "duplicate target or filename in manifest row " NR > "/dev/stderr"
                invalid = 1
                exit
            }
            if ($6 == "true" && ($5 != "true" || $7 == "none" || $8 != "true")) {
                print "published target lacks ci/installer/self_update in row " NR > "/dev/stderr"
                invalid = 1
                exit
            }
            if ($2 == target_os && $3 == target_arch && $6 == "true" && $7 == "systemd") {
                selected = $4
                selected_count++
            }
        }
        END {
            if (invalid) {
                exit 1
            }
            if (NR < 2 || selected_count != 1) {
                print "manifest must contain exactly one published systemd target for " target_os "/" target_arch > "/dev/stderr"
                exit 1
            }
            print selected
        }
    ' "$TMP_TARGET_MANIFEST_PATH"
}

download_and_select_release_target() {
    local target_os="$1"
    local target_arch="$2"
    local manifest_name="wait-agent-targets.tsv"
    local selected_binary

    TMP_TARGET_MANIFEST_PATH="$(mktemp)"
    if ! download_release_asset "$(build_release_asset_url "$manifest_name")" "$TMP_TARGET_MANIFEST_PATH" 262144; then
        log_err "无法下载 ${manifest_name}，拒绝猜测发布资产名称"
        return 1
    fi
    # review-2026-08-18 P2-15: target selection is itself an authorization
    # decision. It is always signature-verified, even when an operator uses the
    # emergency binary checksum/signature bypass.
    if ! verify_release_signature "$TMP_TARGET_MANIFEST_PATH" "$manifest_name"; then
        return 1
    fi
    if ! selected_binary="$(select_release_binary_from_manifest "$target_os" "$target_arch")"; then
        return 1
    fi
    BINARY_NAME="$selected_binary"
}

verify_downloaded_release_file() {
    local file_path="$1"
    local file_name="$2"
    local checksum_path expected_hash actual_hash

    if [[ "$SKIP_SIGNATURE_VERIFY" == "1" ]]; then
        if [[ "$ALLOW_UNSAFE_SKIP" != "1" ]]; then
            log_err "拒绝跳过 ECDSA 签名校验"
            return 1
        fi
        log_err "高危: 已跳过 ECDSA 签名校验"
    elif ! verify_release_signature "$file_path" "$file_name"; then
        return 1
    fi

    if [[ "$SKIP_CHECKSUM_VERIFY" == "1" ]]; then
        if [[ "$ALLOW_UNSAFE_SKIP" != "1" ]]; then
            log_err "拒绝跳过 SHA-256 校验"
            return 1
        fi
        log_err "高危: 已跳过 SHA-256 校验"
        return 0
    fi

    if ! checksum_path="$(download_release_checksum_sidecar "$file_name")"; then
        log_err "无法下载 ${file_name}.sha256，拒绝安装"
        return 1
    fi
    expected_hash="$(awk 'NF >= 1 {print $1; exit}' "$checksum_path")"
    rm -f "$checksum_path"
    if [[ ! "$expected_hash" =~ ^[0-9a-fA-F]{64}$ ]]; then
        log_err "${file_name}.sha256 内容无效"
        return 1
    fi
    expected_hash="$(printf '%s' "$expected_hash" | tr 'A-F' 'a-f')"
    actual_hash="$(sha256_file "$file_path")"
    if [[ "$actual_hash" != "$expected_hash" ]]; then
        log_err "SHA-256 校验失败: ${file_name}"
        return 1
    fi
    log_ok "SHA-256 校验通过"
}

quote_environment_value() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '"%s"' "$value"
}

quote_unit_value() {
    quote_environment_value "$1"
}

write_staged_environment() {
    TMP_ENV_PATH="$(mktemp "${INSTALL_DIR}/.${SERVICE_NAME}.env.new.XXXXXX")"
    {
        printf 'AGENT_ENDPOINT=%s\n' "$(quote_environment_value "$ENDPOINT")"
        printf 'AGENT_TOKEN=%s\n' "$(quote_environment_value "$TOKEN")"
    } > "$TMP_ENV_PATH"
    chmod 600 "$TMP_ENV_PATH"
}

write_staged_service() {
    TMP_SERVICE_PATH="$(mktemp "${SYSTEMD_DIR}/.${SERVICE_NAME}.service.new.XXXXXX")"
    cat > "$TMP_SERVICE_PATH" << EOF
[Unit]
Description=Wait Agent Service
After=network.target

[Service]
Type=simple
EnvironmentFile=-$(quote_unit_value "$ENV_FILE")
ExecStart=$(quote_unit_value "$AGENT_PATH")
WorkingDirectory=$(quote_unit_value "$INSTALL_DIR")
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
ReadWritePaths=$(quote_unit_value "$INSTALL_DIR")

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$TMP_SERVICE_PATH"
}

backup_file() {
    local source_path="$1"
    local backup_var="$2"
    local existed_var="$3"
    local backup_path=""

    if [[ -f "$source_path" ]]; then
        backup_path="$(mktemp "${source_path}.rollback.XXXXXX")"
        if ! cp -p "$source_path" "$backup_path"; then
            rm -f "$backup_path"
            return 1
        fi
        printf -v "$backup_var" '%s' "$backup_path"
        printf -v "$existed_var" '%s' 1
    fi
}

process_environment_matches() {
    local pid="$1"
    local environment_path="${PROC_ROOT}/${pid}/environ"
    local entry endpoint_seen=0 token_seen=0

    [[ -r "$environment_path" ]] || return 1
    while IFS= read -r entry; do
        if [[ "$entry" == "AGENT_ENDPOINT=$ENDPOINT" ]]; then
            endpoint_seen=1
        elif [[ "$entry" == "AGENT_TOKEN=$TOKEN" ]]; then
            token_seen=1
        fi
    done < <(tr '\0' '\n' < "$environment_path")
    [[ "$endpoint_seen" == "1" && "$token_seen" == "1" ]]
}

service_health_matches_install() {
    local pid process_hash

    systemctl is-active --quiet "$SERVICE_UNIT" || return 1
    pid="$(systemctl show "$SERVICE_UNIT" --property MainPID --value 2>/dev/null)"
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    [[ -r "${PROC_ROOT}/${pid}/exe" ]] || return 1
    process_hash="$(sha256_file "${PROC_ROOT}/${pid}/exe")"
    [[ "$process_hash" == "$EXPECTED_BINARY_HASH" ]] || return 1
    process_environment_matches "$pid"
}

wait_for_service_health() {
    local attempt
    for ((attempt = 1; attempt <= HEALTH_ATTEMPTS; attempt++)); do
        if service_health_matches_install; then
            return 0
        fi
        if ((attempt < HEALTH_ATTEMPTS)); then
            sleep "$HEALTH_POLL_INTERVAL"
        fi
    done
    return 1
}

commit_installation() {
    COMMIT_STARTED=1
    mv -f "$TMP_DOWNLOAD_PATH" "$AGENT_PATH" || return 1
    TMP_DOWNLOAD_PATH=""
    mv -f "$TMP_ENV_PATH" "$ENV_FILE" || return 1
    TMP_ENV_PATH=""
    mv -f "$TMP_SERVICE_PATH" "$SERVICE_FILE" || return 1
    TMP_SERVICE_PATH=""

    if [[ "$RUNTIME_USER" != "root" ]]; then
        chown "$RUNTIME_USER:$RUNTIME_GROUP" "$INSTALL_DIR" "$AGENT_PATH" || return 1
    fi
    systemctl daemon-reload || return 1
    systemctl enable "$SERVICE_UNIT" || return 1
    systemctl restart "$SERVICE_UNIT" || return 1
    wait_for_service_health
}

uninstall_agent() {
    AGENT_PATH="$INSTALL_DIR/agent"
    SERVICE_FILE="${SYSTEMD_DIR}/${SERVICE_NAME}.service"
    ENV_FILE="${INSTALL_DIR}/${SERVICE_NAME}.env"
    SERVICE_UNIT="${SERVICE_NAME}.service"

    log_step "卸载 wait agent..."
    systemctl stop "$SERVICE_UNIT" >/dev/null 2>&1 || true
    systemctl disable "$SERVICE_UNIT" >/dev/null 2>&1 || true
    rm -f "$SERVICE_FILE" "$AGENT_PATH" "$ENV_FILE"
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed "$SERVICE_UNIT" >/dev/null 2>&1 || true
    rmdir "$INSTALL_DIR" >/dev/null 2>&1 || true
    log_ok "卸载完成"
}

ENDPOINT=""
TOKEN=""
INSTALL_DIR="/opt/wait"
SERVICE_NAME="wait-agent"
AGENT_USER="wait-agent"
RUNTIME_USER="root"
RUNTIME_GROUP="root"
UNINSTALL=0
TOKEN_FROM_STDIN=0
TOKEN_FROM_ARGUMENT=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --uninstall) UNINSTALL=1; shift ;;
        --help|-h) usage; exit 0 ;;
        --endpoint) require_value "$1" "$#"; ENDPOINT="$2"; shift 2 ;;
        --token) require_value "$1" "$#"; TOKEN="$2"; TOKEN_FROM_ARGUMENT=1; shift 2 ;;
        --token-stdin) TOKEN_FROM_STDIN=1; shift ;;
        --install-dir) require_value "$1" "$#"; INSTALL_DIR="$2"; shift 2 ;;
        --install-service-name) require_value "$1" "$#"; SERVICE_NAME="$2"; shift 2 ;;
        *) log_err "未知参数: $1"; usage; exit 1 ;;
    esac
done

if [[ "$TOKEN_FROM_STDIN" == "1" && "$TOKEN_FROM_ARGUMENT" == "1" ]]; then
    log_err "--token 与 --token-stdin 不能同时使用"
    exit 1
fi
if [[ "$TOKEN_FROM_STDIN" == "1" ]]; then
    if ! IFS= read -r TOKEN || [[ -z "$TOKEN" ]]; then
        log_err "无法从 stdin 读取 Agent token"
        exit 1
    fi
fi

validate_inputs
preflight

if [[ "$UNINSTALL" == "1" ]]; then
    uninstall_agent
    exit 0
fi
if [[ -z "$ENDPOINT" || -z "$TOKEN" ]]; then
    usage
    exit 1
fi

case "$(uname -m)" in
    x86_64) ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    *) log_err "不支持的架构: $(uname -m)"; exit 1 ;;
esac

if ! download_and_select_release_target linux "$ARCH"; then
    log_err "签名 target manifest 不支持 linux/${ARCH} systemd 安装"
    exit 1
fi

SERVICE_UNIT="${SERVICE_NAME}.service"
AGENT_PATH="${INSTALL_DIR}/agent"
ENV_FILE="${INSTALL_DIR}/${SERVICE_NAME}.env"
SERVICE_FILE="${SYSTEMD_DIR}/${SERVICE_UNIT}"
DOWNLOAD_URL="$(build_release_asset_url "$BINARY_NAME")"

if [[ ! -d "$INSTALL_DIR" ]]; then
    mkdir -p "$INSTALL_DIR"
    INSTALL_DIR_CREATED=1
fi
chmod 700 "$INSTALL_DIR"

log_step "下载并验证 agent 二进制..."
TMP_DOWNLOAD_PATH="$(mktemp "${INSTALL_DIR}/.agent.download.XXXXXX")"
download_release_asset "$DOWNLOAD_URL" "$TMP_DOWNLOAD_PATH"
verify_downloaded_release_file "$TMP_DOWNLOAD_PATH" "$BINARY_NAME"
chmod 755 "$TMP_DOWNLOAD_PATH"
EXPECTED_BINARY_HASH="$(sha256_file "$TMP_DOWNLOAD_PATH")"
select_runtime_identity

write_staged_environment
write_staged_service

if systemctl is-active --quiet "$SERVICE_UNIT"; then
    WAS_ACTIVE=1
fi
if systemctl is-enabled --quiet "$SERVICE_UNIT"; then
    WAS_ENABLED=1
fi
backup_file "$AGENT_PATH" BINARY_BACKUP_PATH HAD_BINARY
backup_file "$ENV_FILE" ENV_BACKUP_PATH HAD_ENV
backup_file "$SERVICE_FILE" SERVICE_BACKUP_PATH HAD_SERVICE

# review-2026-08-17 P2-32: atomically replace all installation files, force a
# restart, then verify the live process hash and effective credentials. Any
# failure restores the prior binary/config/unit and active/enabled state.
if ! commit_installation; then
    rollback_installation || true
    log_err "安装失败，已尝试恢复旧版本"
    exit 1
fi

INSTALL_SUCCEEDED=1
echo
log_ok "安装完成，运行进程与本次签名产物及 endpoint/token 一致。"
log_info "  服务: systemctl status $SERVICE_NAME"
log_info "  日志: journalctl -u $SERVICE_NAME -f"
echo
