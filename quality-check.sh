#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

run_step() {
  local name="$1"
  shift
  echo ""
  echo "===== ${name} ====="
  "$@"
}

require_dir() {
  local dir="$1"
  if [[ ! -d "$dir" ]]; then
    echo "[ERROR] Missing directory: $dir" >&2
    exit 1
  fi
}

require_executable() {
  local path="$1"
  local install_hint="$2"
  if [[ ! -x "$path" ]]; then
    echo "[ERROR] Missing executable: $path" >&2
    echo "        Install with: $install_hint" >&2
    exit 1
  fi
}

check_action_pins() {
  local workflow_file line line_number action_ref
  local failed=0

  for workflow_file in "$@"; do
    line_number=0
    while IFS= read -r line; do
      ((line_number += 1))
      if [[ ! "$line" =~ ^[[:space:]-]*uses:[[:space:]]*([^[:space:]#]+) ]]; then
        continue
      fi

      action_ref="${BASH_REMATCH[1]}"
      if [[ "$action_ref" == ./* ]]; then
        continue
      fi
      if [[ "$action_ref" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(/[^@[:space:]]+)?@[0-9a-f]{40}$ ]]; then
        continue
      fi
      if [[ "$action_ref" =~ ^docker://[^@[:space:]]+@sha256:[0-9a-f]{64}$ ]]; then
        continue
      fi

      echo "[ERROR] Mutable or invalid action reference: ${workflow_file}:${line_number}: ${action_ref}" >&2
      failed=1
    done < "$workflow_file"
  done

  if [[ "$failed" -ne 0 ]]; then
    return 1
  fi
}

require_dir "${ROOT_DIR}/wait-main"
require_dir "${ROOT_DIR}/wait-agent-main"
require_dir "${ROOT_DIR}/wait-web-next"

GOVULNCHECK_BIN="${GOVULNCHECK_BIN:-$(go env GOPATH)/bin/govulncheck}"
ACTIONLINT_BIN="${ACTIONLINT_BIN:-$(go env GOPATH)/bin/actionlint}"
require_executable "$GOVULNCHECK_BIN" "go install golang.org/x/vuln/cmd/govulncheck@v1.6.0"
require_executable "$ACTIONLINT_BIN" "go install github.com/rhysd/actionlint/cmd/actionlint@v1.7.7"
govulncheck_version="$("$GOVULNCHECK_BIN" -version 2>&1)"
if [[ "$govulncheck_version" != *"Scanner: govulncheck@v1.6.0"* ]]; then
  echo "[ERROR] govulncheck must be v1.6.0" >&2
  echo "        Install with: go install golang.org/x/vuln/cmd/govulncheck@v1.6.0" >&2
  exit 1
fi
actionlint_version="$("$ACTIONLINT_BIN" -version 2>&1)"
if [[ "$actionlint_version" != *"v1.7.7"* ]]; then
  echo "[ERROR] actionlint must be v1.7.7" >&2
  echo "        Install with: go install github.com/rhysd/actionlint/cmd/actionlint@v1.7.7" >&2
  exit 1
fi

# review-2026-08-17 P2-2: record the exact local toolchain used by the gate.
run_step "toolchain: wait-main Go" bash -c "cd '${ROOT_DIR}/wait-main' && go version"
run_step "toolchain: wait-agent-main Go" bash -c "cd '${ROOT_DIR}/wait-agent-main' && go version"
run_step "toolchain: govulncheck" "$GOVULNCHECK_BIN" -version
run_step "toolchain: Node" node --version
run_step "toolchain: npm" npm --version
run_step "toolchain: actionlint" "$ACTIONLINT_BIN" -version

shopt -s nullglob
workflow_files=()
for workflow_dir in \
  "${ROOT_DIR}/wait-main/.github/workflows" \
  "${ROOT_DIR}/wait-agent-main/.github/workflows" \
  "${ROOT_DIR}/wait-web-next/.github/workflows" \
  "${ROOT_DIR}/wait-website/.github/workflows" \
  "${ROOT_DIR}/wait-release/.github/workflows"; do
  if [[ -d "$workflow_dir" ]]; then
    workflow_files+=("$workflow_dir"/*.yml "$workflow_dir"/*.yaml)
  fi
done
shopt -u nullglob
if [[ ${#workflow_files[@]} -eq 0 ]]; then
  echo "[ERROR] No GitHub Actions workflows found" >&2
  exit 1
fi
# review-2026-08-17 P2-3: third-party Actions must be immutable commits (or image digests).
run_step "workflows: immutable action refs" check_action_pins "${workflow_files[@]}"
run_step "workflows: actionlint" "$ACTIONLINT_BIN" -shellcheck= "${workflow_files[@]}"

# review-2026-08-17 P2-10/P2-11/P2-31: keep one canonical installer
# implementation and syntax-check every published/compatibility entry point.
installer_scripts=(
  "${ROOT_DIR}/quality-check.sh"
  "${ROOT_DIR}/release-unified.sh"
  "${ROOT_DIR}/wait-main/install-wait.sh"
  "${ROOT_DIR}/wait-agent-main/install.sh"
  "${ROOT_DIR}/wait-agent-main/scripts/verify-release-targets.sh"
  "${ROOT_DIR}/wait-release/install-wait.sh"
  "${ROOT_DIR}/wait-release/install-agent.sh"
  "${ROOT_DIR}/wait-release/release-unified.sh"
  "${ROOT_DIR}/wait-release/publish-release-output.sh"
  "${ROOT_DIR}/wait-release/tests/install-agent-smoke.sh"
)
# review-2026-09-20 R11: bash accepts only one script; remaining paths are arguments.
for installer_script in "${installer_scripts[@]}"; do
  run_step "installers: bash syntax ${installer_script}" bash -n "$installer_script"
done
run_step "quality gate: canonical script copy" diff "${ROOT_DIR}/quality-check.sh" "${ROOT_DIR}/wait-release/quality-check.sh"
run_step \
  "installers: canonical wait installer copy" \
  diff \
  "${ROOT_DIR}/wait-main/install-wait.sh" \
  "${ROOT_DIR}/wait-release/install-wait.sh"
run_step \
  "release: unified script copy" \
  diff \
  "${ROOT_DIR}/release-unified.sh" \
  "${ROOT_DIR}/wait-release/release-unified.sh"
run_step "installers: legacy agent compatibility help" \
  "${ROOT_DIR}/wait-agent-main/install.sh" --help
run_step "release: Agent target manifest consistency" \
  "${ROOT_DIR}/wait-agent-main/scripts/verify-release-targets.sh" \
  --release-dir "${ROOT_DIR}/wait-release"
run_step "installers: agent install/upgrade/rollback smoke" \
  "${ROOT_DIR}/wait-release/tests/install-agent-smoke.sh"

# Preserve the selected PATH/toolchain in subprocesses (review-2026-09-20 R11).
# Backend (wait-main)
run_step "wait-main: go test" bash -c "cd '${ROOT_DIR}/wait-main' && go test ./..."
run_step "wait-main: go test -race" bash -c "cd '${ROOT_DIR}/wait-main' && go test -race ./..."
run_step "wait-main: go vet" bash -c "cd '${ROOT_DIR}/wait-main' && go vet ./..."
run_step "wait-main: govulncheck" bash -c "cd '${ROOT_DIR}/wait-main' && '${GOVULNCHECK_BIN}' ./..."

# Agent (wait-agent-main)
run_step "wait-agent-main: go test" bash -c "cd '${ROOT_DIR}/wait-agent-main' && go test ./..."
run_step "wait-agent-main: go test -race" bash -c "cd '${ROOT_DIR}/wait-agent-main' && go test -race ./..."
run_step "wait-agent-main: go vet" bash -c "cd '${ROOT_DIR}/wait-agent-main' && go vet ./..."
run_step "wait-agent-main: govulncheck" bash -c "cd '${ROOT_DIR}/wait-agent-main' && '${GOVULNCHECK_BIN}' ./..."

# Frontend (wait-web-next)
# review-2026-08-17 P3-15: audit both the shipped graph and the complete build/test graph.
run_step "wait-web-next: npm ci" bash -c "cd '${ROOT_DIR}/wait-web-next' && npm ci --silent"
run_step "wait-web-next: npm audit (production)" bash -c "cd '${ROOT_DIR}/wait-web-next' && npm audit --omit=dev --audit-level=high"
run_step "wait-web-next: npm audit (all)" bash -c "cd '${ROOT_DIR}/wait-web-next' && npm audit --audit-level=moderate"
run_step "wait-web-next: npm run test:unit" bash -c "cd '${ROOT_DIR}/wait-web-next' && npm run test:unit"
run_step "wait-web-next: npm run build" bash -c "cd '${ROOT_DIR}/wait-web-next' && npm run build"
run_step "wait-web-next: npm run lint" bash -c "cd '${ROOT_DIR}/wait-web-next' && npm run lint"
run_step "wait-web-next: npm run test:e2e" bash -c "cd '${ROOT_DIR}/wait-web-next' && npm run test:e2e"

# Marketing site (wait-website)
#
# 之前完全不在质量门禁里（review-2026-07-26）：它没有 test/lint 脚本，但 build
# 里的 `tsc -b` 至少能挡住类型错误。目录不存在时跳过，保持脚本在精简 checkout 下可用。
if [[ -d "${ROOT_DIR}/wait-website" ]]; then
  run_step "wait-website: npm ci" bash -c "cd '${ROOT_DIR}/wait-website' && npm ci --silent"
  run_step "wait-website: npm audit (production)" bash -c "cd '${ROOT_DIR}/wait-website' && npm audit --omit=dev --audit-level=high"
  run_step "wait-website: npm audit (all)" bash -c "cd '${ROOT_DIR}/wait-website' && npm audit --audit-level=moderate"
  run_step "wait-website: npm run build" bash -c "cd '${ROOT_DIR}/wait-website' && npm run build"
else
  echo ""
  echo "===== wait-website: skipped (directory not present) ====="
fi

echo ""
echo "All quality checks completed."
