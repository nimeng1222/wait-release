#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=release-version-plan.sh
source "${SCRIPT_DIR}/release-version-plan.sh"

assert_equal() {
  local label="$1"
  local actual="$2"
  local expected="$3"
  if [ "${actual}" != "${expected}" ]; then
    printf 'FAIL: %s: got %s, want %s\n' "${label}" "${actual}" "${expected}" >&2
    exit 1
  fi
}

resolve_release_version_plan "0.1.69" "0.1.60" "same" "same"
assert_equal "unchanged main" "${MAIN_VERSION}" "v0.1.70"
assert_equal "unchanged agent" "${AGENT_VERSION}" "v0.1.60"
assert_equal "unchanged agent publish" "${AGENT_RELEASE_REQUIRED}" "0"

resolve_release_version_plan "0.1.69" "0.1.60" "new" "old"
assert_equal "changed agent" "${AGENT_VERSION}" "v0.1.61"
assert_equal "changed agent publish" "${AGENT_RELEASE_REQUIRED}" "1"

resolve_release_version_plan "0.1.69" "0.1.60" "same" "same" 0 "v1.2.3" "v2.3.4"
assert_equal "explicit main" "${MAIN_VERSION}" "v1.2.3"
assert_equal "explicit agent" "${AGENT_VERSION}" "v2.3.4"
assert_equal "explicit agent publish" "${AGENT_RELEASE_REQUIRED}" "1"

resolve_release_version_plan "0.1.69" "0.1.60" "new" "old" 1
assert_equal "reuse main" "${MAIN_VERSION}" "v0.1.69"
assert_equal "reuse agent" "${AGENT_VERSION}" "v0.1.60"
assert_equal "reuse agent publish" "${AGENT_RELEASE_REQUIRED}" "1"

resolve_release_version_plan "0.1.69" "0.1.60" "same" "same" 0 "" "" 1
assert_equal "forced agent publish" "${AGENT_RELEASE_REQUIRED}" "1"

resolve_release_version_plan "0.1.69" "0.1.60" "same" "same" 0 "" "v0.1.60"
assert_equal "explicit current agent publish" "${AGENT_RELEASE_REQUIRED}" "1"

printf 'release version plan tests passed\n'
