#!/usr/bin/env bash
set -euo pipefail

# Static assertions keeping install-wait.sh's agent-uninstall menu entry (option 8)
# converged on the canonical install-agent.sh --uninstall: no second uninstall
# implementation may live in the menu path (review-2026-10-05).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANONICAL="${ROOT_DIR}/install-wait.sh"
SYNC_COPY="${ROOT_DIR}/../wait-main/install-wait.sh"

fail() {
    printf '[FAIL] %s\n' "$1" >&2
    exit 1
}

assert_file_contains() {
    local file_path="$1"
    local expected="$2"
    if ! grep -Fq "$expected" "$file_path"; then
        fail "${file_path} does not contain expected text: ${expected}"
    fi
}

assert_file_not_contains() {
    local file_path="$1"
    local unexpected="$2"
    if grep -Fq "$unexpected" "$file_path"; then
        fail "${file_path} must not contain: ${unexpected}"
    fi
}

# 菜单路径（uninstall_agent 函数体）不得再包含任何独立清理实现。
extract_uninstall_agent_body() {
    awk '
        /^uninstall_agent\(\)/ { in_fn = 1 }
        in_fn && /^\}/ { print; exit }
        in_fn { print }
    ' "$1"
}

assert_canonical_copy_in_sync() {
    if ! diff -q "$CANONICAL" "$SYNC_COPY" >/dev/null; then
        fail "install-wait.sh copies diverged: ${SYNC_COPY}"
    fi
}

assert_syntax_ok() {
    bash -n "$CANONICAL" || fail "bash -n failed: ${CANONICAL}"
    bash -n "$SYNC_COPY" || fail "bash -n failed: ${SYNC_COPY}"
}

assert_menu_delegates_uninstall() {
    assert_file_contains "$CANONICAL" '8) uninstall_agent ;;'
    # 菜单文案必须表达无痕卸载语义
    assert_file_contains "$CANONICAL" '卸载 agent（无痕：删用户/数据/日志）'
    # 本地有 canonical 脚本时直接代为执行 --uninstall
    # shellcheck disable=SC2016  # 断言对象就是这段源码字面量
    assert_file_contains "$CANONICAL" 'bash "$installer" --uninstall'
    # 本地没有时给出去 canonical 入口的下载指引（复用同一 release 资产通道）
    assert_file_contains "$CANONICAL" 'build_download_url "install-agent.sh"'
    assert_file_contains "$CANONICAL" 'install-agent.sh --uninstall'
}

assert_no_second_uninstall_implementation() {
    local body
    body="$(extract_uninstall_agent_body "$CANONICAL")"
    if [ -z "$body" ]; then
        fail "uninstall_agent function not found in ${CANONICAL}"
    fi
    local snippet
    snippet="${TEST_ROOT}/uninstall-agent-body.sh"
    printf '%s\n' "$body" > "$snippet"

    # 卸载函数必须纯委托：不得直接触碰 systemd/文件/用户/日志
    local forbidden
    for forbidden in \
        'systemctl' \
        'journalctl' \
        'rm ' \
        'userdel' \
        'groupdel'
    do
        assert_file_not_contains "$snippet" "$forbidden"
    done

    # 遗留清理面（多服务名 / OpenRC / launchd / 散落目录）整体不得回归。
    # 注：/var/lib、/etc 遗留路径的删除属于 canonical install-agent.sh 的职责，
    # 由函数体级的 'rm '/systemctl 负断言保证本脚本不碰它们。
    for forbidden in \
        'wait_monitor_agent' \
        'rc-service' \
        'rc-update' \
        'launchctl' \
        'com.wait.wait-agent' \
        'init.d' \
        '/usr/local/wait'
    do
        assert_file_not_contains "$CANONICAL" "$forbidden"
    done
}

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/wait-installer-smoke.XXXXXX")"
cleanup() {
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

assert_canonical_copy_in_sync
assert_syntax_ok
assert_menu_delegates_uninstall
assert_no_second_uninstall_implementation

printf 'install-wait smoke tests passed\n'
