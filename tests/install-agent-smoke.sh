#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="${ROOT_DIR}/install-agent.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/wait-agent-installer-smoke.XXXXXX")"

cleanup() {
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
    printf '[FAIL] %s\n' "$1" >&2
    exit 1
}

assert_file_contains() {
    local file_path="$1"
    local expected="$2"
    if ! grep -Fq "$expected" "$file_path"; then
        fail "${file_path} does not contain expected text"
    fi
}

write_mock_commands() {
    local mock_bin="$1"
    mkdir -p "$mock_bin"

    cat > "${mock_bin}/uname" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    -s) printf 'Linux\n' ;;
    -m) printf 'x86_64\n' ;;
    *) printf 'Linux\n' ;;
esac
EOF

    cat > "${mock_bin}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output_path=""
url=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output|-o) output_path="$2"; shift 2 ;;
        https://*) url="$1"; shift ;;
        *) shift ;;
    esac
done
[[ -n "$output_path" && -n "$url" ]]
asset_name="${url##*/}"
printf '%s\n' "$asset_name" >> "$MOCK_DOWNLOAD_LOG"
cp "${MOCK_RELEASE_ASSET_DIR}/${asset_name}" "$output_path"
EOF

    cat > "${mock_bin}/openssl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" != "dgst" || "${2:-}" != "-sha256" || "${3:-}" != "-verify" ]]; then
    printf 'unexpected openssl command: %s\n' "$*" >&2
    exit 1
fi
signature_path="${6:-}"
file_path="${7:-}"
[[ -s "$signature_path" && -s "$file_path" ]]
if head -n 1 "$file_path" | grep -Fq $'schema\tos\tarch\tfilename'; then
    printf 'wait-agent-targets.tsv\n' >> "$MOCK_SIGNATURE_LOG"
else
    printf '%s\n' "$(basename "$file_path")" >> "$MOCK_SIGNATURE_LOG"
fi
EOF

    cat > "${mock_bin}/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
command_name="${1:-}"
active_path="${MOCK_SYSTEMCTL_STATE_DIR}/active"
enabled_path="${MOCK_SYSTEMCTL_STATE_DIR}/enabled"
restart_count_path="${MOCK_SYSTEMCTL_STATE_DIR}/restart-count"
pid=4242

case "$command_name" in
    list-units|daemon-reload|reset-failed)
        exit 0
        ;;
    is-active)
        [[ -f "$active_path" ]]
        ;;
    is-enabled)
        [[ -f "$enabled_path" ]]
        ;;
    enable)
        : > "$enabled_path"
        ;;
    disable)
        rm -f "$enabled_path"
        ;;
    stop)
        rm -f "$active_path"
        rm -rf "${MOCK_PROC_ROOT:?}/${pid}"
        ;;
    restart)
        restart_count=0
        if [[ -f "$restart_count_path" ]]; then
            restart_count="$(<"$restart_count_path")"
        fi
        restart_count=$((restart_count + 1))
        printf '%s\n' "$restart_count" > "$restart_count_path"
        : > "$active_path"
        rm -rf "${MOCK_PROC_ROOT:?}/${pid}"
        mkdir -p "${MOCK_PROC_ROOT}/${pid}"
        ln -s "$MOCK_AGENT_PATH" "${MOCK_PROC_ROOT}/${pid}/exe"

        unset AGENT_ENDPOINT AGENT_TOKEN
        # The generated EnvironmentFile uses shell-compatible double quotes.
        # shellcheck disable=SC1090
        source "$MOCK_ENV_FILE"
        if [[ "${MOCK_HEALTH_FAIL_ON_RESTART:-0}" == "$restart_count" ]]; then
            AGENT_TOKEN="health-check-mismatch"
        fi
        printf 'AGENT_ENDPOINT=%s\0AGENT_TOKEN=%s\0' \
            "$AGENT_ENDPOINT" "$AGENT_TOKEN" > "${MOCK_PROC_ROOT}/${pid}/environ"
        ;;
    show)
        if [[ -f "$active_path" ]]; then
            printf '%s\n' "$pid"
        else
            printf '0\n'
        fi
        ;;
    *)
        printf 'unexpected systemctl command: %s\n' "$*" >&2
        exit 1
        ;;
esac
EOF

    chmod +x "${mock_bin}/uname" "${mock_bin}/curl" "${mock_bin}/openssl" "${mock_bin}/systemctl"
}

new_case() {
    local name="$1"
    CASE_ROOT="${TEST_ROOT}/${name}"
    INSTALL_DIR="${CASE_ROOT}/install"
    SYSTEMD_DIR="${CASE_ROOT}/systemd"
    PROC_ROOT="${CASE_ROOT}/proc"
    STATE_DIR="${CASE_ROOT}/state"
    MOCK_BIN="${CASE_ROOT}/mock-bin"
    NEW_BINARY="${CASE_ROOT}/new-agent"
    RELEASE_ASSET_DIR="${CASE_ROOT}/release-assets"
    DOWNLOAD_LOG="${CASE_ROOT}/downloads.log"
    SIGNATURE_LOG="${CASE_ROOT}/signatures.log"
    mkdir -p "$SYSTEMD_DIR" "$PROC_ROOT" "$STATE_DIR" "$RELEASE_ASSET_DIR"
    printf '#!/bin/sh\n# new signed agent\nexit 0\n' > "$NEW_BINARY"
    chmod +x "$NEW_BINARY"
    cp "$NEW_BINARY" "${RELEASE_ASSET_DIR}/wait-agent-linux-amd64"
    sha256sum "${RELEASE_ASSET_DIR}/wait-agent-linux-amd64" | awk '{print $1}' \
        > "${RELEASE_ASSET_DIR}/wait-agent-linux-amd64.sha256"
    printf 'mock binary signature\n' > "${RELEASE_ASSET_DIR}/wait-agent-linux-amd64.sig"
    cp "${ROOT_DIR}/../wait-agent-main/update/release-targets.tsv" \
        "${RELEASE_ASSET_DIR}/wait-agent-targets.tsv"
    printf 'mock manifest signature\n' > "${RELEASE_ASSET_DIR}/wait-agent-targets.tsv.sig"
    write_mock_commands "$MOCK_BIN"
}

seed_existing_install() {
    mkdir -p "$INSTALL_DIR"
    printf '#!/bin/sh\n# old agent\nexit 0\n' > "${INSTALL_DIR}/agent"
    chmod +x "${INSTALL_DIR}/agent"
    cat > "${INSTALL_DIR}/wait-agent.env" <<'EOF'
AGENT_ENDPOINT="https://old.example"
AGENT_TOKEN="old-token"
EOF
    printf 'old unit marker\n' > "${SYSTEMD_DIR}/wait-agent.service"
    : > "${STATE_DIR}/active"
    : > "${STATE_DIR}/enabled"
}

run_installer() {
    local endpoint="$1"
    local token="$2"
    env \
        PATH="${MOCK_BIN}:/usr/bin:/bin:/usr/sbin:/sbin" \
        WAIT_AGENT_INSTALLER_TEST_MODE=1 \
        WAIT_AGENT_INSTALLER_SYSTEMD_DIR="$SYSTEMD_DIR" \
        WAIT_AGENT_INSTALLER_PROC_ROOT="$PROC_ROOT" \
        WAIT_AGENT_INSTALLER_HEALTH_ATTEMPTS=2 \
        WAIT_AGENT_INSTALLER_HEALTH_POLL_INTERVAL=0 \
        WAIT_AGENT_RELEASE_REPO_URL="https://release.test/releases" \
        MOCK_RELEASE_ASSET_DIR="$RELEASE_ASSET_DIR" \
        MOCK_DOWNLOAD_LOG="$DOWNLOAD_LOG" \
        MOCK_SIGNATURE_LOG="$SIGNATURE_LOG" \
        MOCK_SYSTEMCTL_STATE_DIR="$STATE_DIR" \
        MOCK_PROC_ROOT="$PROC_ROOT" \
        MOCK_AGENT_PATH="${INSTALL_DIR}/agent" \
        MOCK_ENV_FILE="${INSTALL_DIR}/wait-agent.env" \
        MOCK_HEALTH_FAIL_ON_RESTART="${MOCK_HEALTH_FAIL_ON_RESTART:-0}" \
        "$INSTALLER" \
        --endpoint "$endpoint" \
        --token "$token" \
        --install-dir "$INSTALL_DIR"
}

test_first_install() {
    new_case first-install
    run_installer "https://first.example" "first-token" > "${CASE_ROOT}/installer.log" 2>&1
    cmp "$NEW_BINARY" "${INSTALL_DIR}/agent"
    assert_file_contains "${INSTALL_DIR}/wait-agent.env" 'AGENT_ENDPOINT="https://first.example"'
    assert_file_contains "${INSTALL_DIR}/wait-agent.env" 'AGENT_TOKEN="first-token"'
    [[ -f "${STATE_DIR}/active" && -f "${STATE_DIR}/enabled" ]]
    [[ "$(<"${STATE_DIR}/restart-count")" == "1" ]]
    assert_file_contains "$DOWNLOAD_LOG" 'wait-agent-targets.tsv'
    assert_file_contains "$DOWNLOAD_LOG" 'wait-agent-targets.tsv.sig'
    assert_file_contains "$DOWNLOAD_LOG" 'wait-agent-linux-amd64'
    assert_file_contains "$SIGNATURE_LOG" 'wait-agent-targets.tsv'
    assert_file_contains "$SIGNATURE_LOG" '.agent.download.'
}

test_upgrade() {
    new_case upgrade
    seed_existing_install
    run_installer "https://upgrade.example" "upgrade-token" > "${CASE_ROOT}/installer.log" 2>&1
    cmp "$NEW_BINARY" "${INSTALL_DIR}/agent"
    assert_file_contains "${INSTALL_DIR}/wait-agent.env" 'AGENT_ENDPOINT="https://upgrade.example"'
    assert_file_contains "${INSTALL_DIR}/wait-agent.env" 'AGENT_TOKEN="upgrade-token"'
    if grep -Fq 'old unit marker' "${SYSTEMD_DIR}/wait-agent.service"; then
        fail "upgrade retained the old unit file"
    fi
    [[ "$(<"${STATE_DIR}/restart-count")" == "1" ]]
}

test_credential_rotation_restarts() {
    new_case credential-rotation
    seed_existing_install
    cp "$NEW_BINARY" "${INSTALL_DIR}/agent"
    run_installer "https://rotated.example" "rotated-token" > "${CASE_ROOT}/installer.log" 2>&1
    assert_file_contains "${PROC_ROOT}/4242/environ" 'AGENT_ENDPOINT=https://rotated.example'
    assert_file_contains "${PROC_ROOT}/4242/environ" 'AGENT_TOKEN=rotated-token'
    [[ "$(<"${STATE_DIR}/restart-count")" == "1" ]]
}

test_health_failure_rolls_back() {
    new_case rollback
    seed_existing_install
    cp "${INSTALL_DIR}/agent" "${CASE_ROOT}/expected-old-agent"
    cp "${INSTALL_DIR}/wait-agent.env" "${CASE_ROOT}/expected-old-env"
    cp "${SYSTEMD_DIR}/wait-agent.service" "${CASE_ROOT}/expected-old-unit"

    MOCK_HEALTH_FAIL_ON_RESTART=1
    if run_installer "https://broken.example" "broken-token" > "${CASE_ROOT}/installer.log" 2>&1; then
        fail "health mismatch unexpectedly succeeded"
    fi
    unset MOCK_HEALTH_FAIL_ON_RESTART

    cmp "${CASE_ROOT}/expected-old-agent" "${INSTALL_DIR}/agent"
    cmp "${CASE_ROOT}/expected-old-env" "${INSTALL_DIR}/wait-agent.env"
    cmp "${CASE_ROOT}/expected-old-unit" "${SYSTEMD_DIR}/wait-agent.service"
    [[ -f "${STATE_DIR}/active" && -f "${STATE_DIR}/enabled" ]]
    [[ "$(<"${STATE_DIR}/restart-count")" == "2" ]]
    if find "$CASE_ROOT" -name '*.rollback.*' -print -quit | grep -q .; then
        fail "successful rollback left backup files behind"
    fi
}

test_special_character_serialization() {
    new_case 'special chars "quoted" & <xml>'
    local endpoint='https://special.example/a path?x=<node>&q="quoted"'
    local token='token with spaces "quotes" \ backslash <xml>&'

    run_installer "$endpoint" "$token" > "${CASE_ROOT}/installer.log" 2>&1
    assert_file_contains "${INSTALL_DIR}/wait-agent.env" \
        'AGENT_ENDPOINT="https://special.example/a path?x=<node>&q=\"quoted\""'
    assert_file_contains "${INSTALL_DIR}/wait-agent.env" \
        'AGENT_TOKEN="token with spaces \"quotes\" \\ backslash <xml>&"'
    assert_file_contains "${SYSTEMD_DIR}/wait-agent.service" 'EnvironmentFile=-"'
    assert_file_contains "${SYSTEMD_DIR}/wait-agent.service" '\"quoted\" & <xml>'

    tr '\0' '\n' < "${PROC_ROOT}/4242/environ" > "${CASE_ROOT}/effective-environ"
    assert_file_contains "${CASE_ROOT}/effective-environ" "AGENT_ENDPOINT=$endpoint"
    assert_file_contains "${CASE_ROOT}/effective-environ" "AGENT_TOKEN=$token"
}

test_first_install
test_upgrade
test_credential_rotation_restarts
test_health_failure_rolls_back
test_special_character_serialization

printf 'install-agent smoke tests passed\n'
