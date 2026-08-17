#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${ROOT_DIR:-$SCRIPT_DIR}"
WEB_DIR="${ROOT_DIR}/wait-web-next"
MAIN_DIR="${ROOT_DIR}/wait-main"
AGENT_DIR="${ROOT_DIR}/wait-agent-main"
OUT_DIR="${OUT_DIR:-${ROOT_DIR}/release-output}"
MAIN_BUILD_DIR="${OUT_DIR}/wait-main"
AGENT_BUILD_DIR="${OUT_DIR}/wait-agent"
WEB_BUILD_DIR="${OUT_DIR}/web"
AGENT_TARGET_MANIFEST="${AGENT_DIR}/update/release-targets.tsv"
INSTALLER_DIR="${INSTALLER_DIR:-${SCRIPT_DIR}}"
if [ ! -f "${INSTALLER_DIR}/install-wait.sh" ] || [ ! -f "${INSTALLER_DIR}/install-agent.sh" ]; then
  INSTALLER_DIR="${ROOT_DIR}/wait-release"
fi
STAGING_ROOT="${STAGING_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/wait-release.XXXXXX")}"
KEEP_STAGING="${KEEP_STAGING:-0}"
MAIN_STAGING_DIR="${STAGING_ROOT}/wait-main"
MAIN_THEME_DIST_DIR="${MAIN_STAGING_DIR}/public/defaultTheme/dist"

MAIN_PRIVATE_REPO="nimeng1222/wait-monitor"
AGENT_PRIVATE_REPO="nimeng1222/wait-agent"
PUBLIC_RELEASE_REPO="nimeng1222/wait-release"
TRUSTED_RELEASE_PUBKEY_PEM='-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE29f9FZIEMzvfTiaJGd6zPgpOZnIL
jndWyXnh3jM+TWNVvBarlcPGAEDxmIQAAYel8QIDJgzIs7xSKE9oLtvmmg==
-----END PUBLIC KEY-----'
RELEASE_SIGNING_KEY="${WAIT_RELEASE_SIGNING_KEY:-}"
RELEASE_SIGNING_PUBKEY_ASSET="RELEASE_PUBKEY.pem"
TEMP_RELEASE_SIGNING_KEY=""
RELEASE_SIGNING_MODE="configured"
TARGET_MANIFEST_STAGED=0

sha256_file() {
  local file_path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${file_path}" | awk '{print $1}'
    return
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${file_path}" | awk '{print $1}'
    return
  fi
  if command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "${file_path}" | awk '{print $NF}'
    return
  fi
  echo "ERROR: no SHA-256 tool found (sha256sum/shasum/openssl)" >&2
  exit 1
}

append_asset_if_exists() {
  local array_name="$1"
  local asset_path="$2"
  local asset_label="${3:-}"
  if [ ! -f "${asset_path}" ]; then
    return
  fi

  local value="${asset_path}"
  if [ -n "${asset_label}" ]; then
    value="${asset_path}#${asset_label}"
  fi

  case "${array_name}" in
    MAIN_ASSETS)
      MAIN_ASSETS+=("${value}")
      ;;
    AGENT_ASSETS)
      AGENT_ASSETS+=("${value}")
      ;;
    PUBLIC_ASSETS)
      PUBLIC_ASSETS+=("${value}")
      ;;
    PUBLIC_AGENT_ASSETS)
      PUBLIC_AGENT_ASSETS+=("${value}")
      ;;
    *)
      echo "ERROR: unsupported asset array ${array_name}" >&2
      exit 1
      ;;
  esac
}

# upload_release_assets 发布（或补传）一个 release。
#
# 第 4 个参数是 target commitish：gh release create 不带 --target 时，会用**默认分支
# 当前的 HEAD** 来打 tag，而不是我们实际编译的那个 commit。unified-release.yml 允许
# 传入 branch/tag/SHA 作为 main_ref，加上 main 随时可能在 checkout 与 publish 之间前进，
# 于是 tag 和 PROVENANCE.json 记录的 commit 会对不上 —— `git checkout <tag> && go build`
# 复现不出发布的二进制。review-2026-07-26 P1-14
upload_release_assets() {
  local repo="$1"
  local tag="$2"
  local notes="$3"
  local target="$4"
  local latest="$5"
  shift 5
  local assets=("$@")

  local target_args=()
  if [ -n "${target}" ]; then
    target_args=(--target "${target}")
  fi

  # 第 5 个参数显式决定这个 release 是不是 GitHub 的 "Latest"。
  #
  # 不能依赖 gh 的默认（"automatic based on date and version"）：公开镜像仓库里
  # 同时有主控和 agent 两条独立递增的版本线，一旦 agent 的版本号超过主控，
  # agent 的镜像 release 就会抢走 Latest —— 而 install-wait.sh 与 install-agent.sh
  # 都靠 /releases/latest/download/<asset> 取资产，主控安装器会立刻 404。
  # review-2026-07-26 复审
  local latest_args=()
  case "${latest}" in
    true)  latest_args=(--latest) ;;
    false) latest_args=(--latest=false) ;;
    "")    ;;
    *)     echo "ERROR: upload_release_assets latest must be true/false/empty, got '${latest}'" >&2; exit 1 ;;
  esac

  local release_exists=0
  if gh release view "${tag}" --repo "${repo}" >/dev/null 2>&1; then
    release_exists=1
  fi

  if [ "${release_exists}" -eq 0 ]; then
    echo "Creating release ${tag} in ${repo} at ${target:-<default branch>}"
    # 数组一律用 "${arr[@]+"${arr[@]}"}" 展开，不能直接写 "${arr[@]}"。
    #
    # macOS 自带的是 bash 3.2.57，在 `set -u` 下把**空数组**的 "${arr[@]}" 判为
    # unbound variable 并直接退出；bash 4.4+ 才把空数组视为已定义。target_args 与
    # latest_args 在多数调用下正好是空的（私有仓库不传 --latest，镜像仓库不传
    # --target），于是脚本在 macOS 上会死在第一次发布调用处，根本发不了版。
    # `${arr[@]+...}` 的 `+` 展开在数组为空时整体消失，两个版本的 bash 行为一致。
    # review-2026-07-27 H-1
    gh release create "${tag}" "${assets[@]+"${assets[@]}"}" --repo "${repo}" --title "Release ${tag}" --notes "${notes}" "${target_args[@]+"${target_args[@]}"}" "${latest_args[@]+"${latest_args[@]}"}"
    return
  fi

  echo "ERROR: release ${tag} already exists in ${repo}. Executable release assets are immutable; publish a new version tag." >&2
  exit 1
}

# assert_release_absent 在**发布任何东西之前**确认目标 release 槽位是空的。
#
# upload_release_assets 自己也会检查，但那是逐个检查、边查边发：第 3 个目标撞车时，
# 前 2 个已经发出去了 —— 留下一个发了一半的版本。这里把全部 4 个槽位一次性查完，
# 让"要么全发，要么一个都不发"成为默认行为。review-2026-07-27 H-2
assert_release_absent() {
  local repo="$1"
  local tag="$2"
  if gh release view "${tag}" --repo "${repo}" >/dev/null 2>&1; then
    echo "ERROR: release ${tag} already exists in ${repo}." >&2
    echo "       Refusing to start publishing, otherwise earlier repos would be left half-published." >&2
    echo "       Publish a new version tag; existing executable assets cannot be overwritten." >&2
    exit 1
  fi
}

write_go_module_inventory() {
  local repo_dir="$1"
  local output_path="$2"
  (
    cd "${repo_dir}"
    go list -mod=readonly -m all
  ) > "${output_path}"
}

cleanup_staging() {
  if [ -n "${TEMP_RELEASE_SIGNING_KEY}" ] && [ -f "${TEMP_RELEASE_SIGNING_KEY}" ]; then
    rm -f "${TEMP_RELEASE_SIGNING_KEY}"
  fi
  if [ "${KEEP_STAGING}" = "1" ]; then
    return
  fi
  rm -rf "${STAGING_ROOT}"
  if [ "${TARGET_MANIFEST_STAGED}" = "1" ] && \
     ! cmp -s "${AGENT_TARGET_MANIFEST}" "${OUT_DIR}/wait-agent-targets.tsv"; then
    echo "ERROR: Agent target manifest was lost while cleaning the staging workspace" >&2
    return 1
  fi
}
trap cleanup_staging EXIT

write_npm_inventory() {
  local repo_dir="$1"
  local output_path="$2"
  (
    cd "${repo_dir}"
    npm ls --all --json
  ) > "${output_path}"
}

write_provenance_metadata() {
  local output_path="$1"
  local node_version
  local npm_version
  local main_go_version
  local agent_go_version
  local web_revision
	local agent_release_required_json="false"
	if [ "${AGENT_RELEASE_REQUIRED}" = "1" ]; then
		agent_release_required_json="true"
	fi
  node_version="$(node -v)"
  npm_version="$(npm -v)"
  main_go_version="$(cd "${MAIN_DIR}" && go env GOVERSION)"
  agent_go_version="$(cd "${AGENT_DIR}" && go env GOVERSION)"
  if [ -d "${WEB_DIR}/.git" ]; then
    web_revision="${WEB_COMMIT:-$(git -C "${WEB_DIR}" rev-parse HEAD 2>/dev/null || true)}"
  else
    web_revision="workspace"
  fi
  cat > "${output_path}" <<EOF
{
  "builder": "release-unified.sh",
  "versions": {
    "wait_main": "${MAIN_VERSION}",
    "wait_agent": "${AGENT_VERSION}"
  },
  "inputs": {
    "wait_main": {
      "repo": "${MAIN_PRIVATE_REPO}",
      "branch": "$(git -C "${MAIN_DIR}" rev-parse --abbrev-ref HEAD)",
      "commit": "$(git -C "${MAIN_DIR}" rev-parse HEAD)"
    },
    "wait_agent": {
      "repo": "${AGENT_PRIVATE_REPO}",
      "branch": "$(git -C "${AGENT_DIR}" rev-parse --abbrev-ref HEAD)",
      "commit": "$(git -C "${AGENT_DIR}" rev-parse HEAD)"
    },
    "wait_web_next": {
      "repo": "nimeng1222/wait-web-next",
      "revision": "${web_revision}"
    }
  },
  "toolchain": {
    "go_wait_main": "${main_go_version}",
    "go_wait_agent": "${agent_go_version}",
    "node": "${node_version}",
    "npm": "${npm_version}"
  },
  "release_routing": {
    "canonical_wait_main_repo": "${MAIN_PRIVATE_REPO}",
    "canonical_wait_agent_repo": "${AGENT_PRIVATE_REPO}",
    "public_installer_repo": "${PUBLIC_RELEASE_REPO}"
  },
  "release_plan": {
    "agent_release_required": ${agent_release_required_json},
    "public_agent_tag": "${PUBLIC_AGENT_TAG}",
    "main_version_reason": "${MAIN_VERSION_REASON}",
    "agent_version_reason": "${AGENT_VERSION_REASON}"
  }
}
EOF
}

write_sha256sums() {
  local output_path="$1"
  shift
  : > "${output_path}"
  for file_path in "$@"; do
    local file_name
    file_name="${file_path#"${OUT_DIR}"/}"
    printf '%s  %s\n' "$(sha256_file "${file_path}")" "${file_name}" >> "${output_path}"
  done
}

write_sha256_sidecar() {
  local file_path="$1"
  local output_path="$2"
  printf '%s\n' "$(sha256_file "${file_path}")" > "${output_path}"
}

agent_update_sequence() {
  local version="$1"
  if [[ ! "${version}" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    echo "ERROR: cannot derive Agent update sequence from ${version}" >&2
    exit 1
  fi
  local major minor patch
  major=$((10#${BASH_REMATCH[1]}))
  minor=$((10#${BASH_REMATCH[2]}))
  patch=$((10#${BASH_REMATCH[3]}))
  if [ "${major}" -ge 1000000 ] || [ "${minor}" -ge 1000000 ] || [ "${patch}" -ge 1000000 ]; then
    echo "ERROR: Agent version components must be below 1000000 for monotonic update sequencing" >&2
    exit 1
  fi
  printf '%s\n' "$((major * 1000000000000 + minor * 1000000 + patch))"
}

write_agent_update_manifest() {
  local output_path="$1"
  if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required to generate the signed Agent update manifest" >&2
    exit 1
  fi
  local targets_json='[]'
  local spec target goos goarch filename file_path length digest
  for spec in "${AGENT_TARGETS[@]}"; do
    IFS='|' read -r goos goarch filename _installer <<< "$spec"
    target="${goos}/${goarch}"
    file_path="${AGENT_BUILD_DIR}/${filename}"
    if [ ! -f "${file_path}" ]; then
      echo "ERROR: Agent update target is missing: ${file_path}" >&2
      exit 1
    fi
    length="$(wc -c < "${file_path}" | tr -d '[:space:]')"
    digest="$(sha256_file "${file_path}")"
    targets_json="$(jq -cn \
      --argjson current "${targets_json}" \
      --arg target "${target}" \
      --arg filename "${filename}" \
      --argjson length "${length}" \
      --arg sha256 "${digest}" \
      '$current + [{target: $target, filename: $filename, length: $length, sha256: $sha256}]')"
  done
  local sequence
  sequence="$(agent_update_sequence "${AGENT_VERSION}")"
  jq -cnS \
    --arg repository "${PUBLIC_RELEASE_REPO}" \
    --arg schema "wait-agent-update/v1" \
    --argjson sequence "${sequence}" \
    --arg tag "${PUBLIC_AGENT_TAG}" \
    --argjson targets "${targets_json}" \
    --arg version "${AGENT_VERSION}" \
    '{repository: $repository, schema: $schema, sequence: $sequence, tag: $tag, targets: $targets, version: $version}' \
    > "${output_path}"
}

normalize_pem_to_one_line() {
  local pem_path="$1"
  tr -d '\r' < "${pem_path}" | sed '/^$/d'
}

trusted_release_public_key_path() {
  local output_path="$1"
  printf '%s\n' "${TRUSTED_RELEASE_PUBKEY_PEM}" > "${output_path}"
}

ensure_openssl_for_signing() {
  if ! command -v openssl >/dev/null 2>&1; then
    echo "ERROR: openssl is required for release signing" >&2
    exit 1
  fi
}

validate_release_signing_key() {
  local derived_pubkey_path
  local trusted_pubkey_path
  local derived_normalized
  local trusted_normalized

  ensure_openssl_for_signing

  if [ -z "${RELEASE_SIGNING_KEY}" ]; then
    echo "ERROR: WAIT_RELEASE_SIGNING_KEY must point to an ECDSA private key PEM file" >&2
    exit 1
  fi
  if [ ! -f "${RELEASE_SIGNING_KEY}" ]; then
    echo "ERROR: release signing key not found: ${RELEASE_SIGNING_KEY}" >&2
    exit 1
  fi

  derived_pubkey_path="$(mktemp)"
  trusted_pubkey_path="$(mktemp)"
  if ! openssl pkey -in "${RELEASE_SIGNING_KEY}" -pubout -out "${derived_pubkey_path}" >/dev/null 2>&1; then
    rm -f "${derived_pubkey_path}" "${trusted_pubkey_path}"
    echo "ERROR: failed to derive public key from WAIT_RELEASE_SIGNING_KEY" >&2
    exit 1
  fi
  trusted_release_public_key_path "${trusted_pubkey_path}"

  derived_normalized="$(normalize_pem_to_one_line "${derived_pubkey_path}")"
  trusted_normalized="$(normalize_pem_to_one_line "${trusted_pubkey_path}")"
  rm -f "${derived_pubkey_path}" "${trusted_pubkey_path}"

  if [ "${derived_normalized}" != "${trusted_normalized}" ]; then
    echo "ERROR: WAIT_RELEASE_SIGNING_KEY does not match the trusted embedded release public key" >&2
    exit 1
  fi
}

generate_dry_run_signing_key() {
  ensure_openssl_for_signing
  TEMP_RELEASE_SIGNING_KEY="$(mktemp "${TMPDIR:-/tmp}/wait-release-signing.XXXXXX.pem")"
  if ! openssl ecparam -name prime256v1 -genkey -noout -out "${TEMP_RELEASE_SIGNING_KEY}" >/dev/null 2>&1; then
    rm -f "${TEMP_RELEASE_SIGNING_KEY}"
    TEMP_RELEASE_SIGNING_KEY=""
    echo "ERROR: failed to generate temporary dry-run signing key" >&2
    exit 1
  fi
  RELEASE_SIGNING_KEY="${TEMP_RELEASE_SIGNING_KEY}"
  RELEASE_SIGNING_MODE="dry-run-temporary"
}

prepare_release_signing_key() {
  if [ -n "${RELEASE_SIGNING_KEY}" ]; then
    validate_release_signing_key
    return
  fi

  if [ "${PUBLISH_RELEASES}" = "1" ]; then
    echo "ERROR: WAIT_RELEASE_SIGNING_KEY must point to an ECDSA private key PEM file" >&2
    exit 1
  fi

  generate_dry_run_signing_key
}

write_release_public_key() {
  local output_path="$1"
  openssl pkey -in "${RELEASE_SIGNING_KEY}" -pubout -out "${output_path}" >/dev/null
}

sign_release_asset() {
  local file_path="$1"
  local signature_path="$2"
  openssl dgst -sha256 -sign "${RELEASE_SIGNING_KEY}" -out "${signature_path}" "${file_path}"
}

manifest_version() {
  local label="$1"
  local manifest_path="${OUT_DIR}/MANIFEST.txt"
  if [ ! -f "${manifest_path}" ]; then
    echo "ERROR: ${manifest_path} not found. Set CURRENT_MAIN_VERSION/CURRENT_AGENT_VERSION explicitly or generate MANIFEST.txt first." >&2
    exit 1
  fi

  local version
  version="$(sed -n "s/^${label}: v//p" "${manifest_path}" | head -n 1)"
  if [ -n "${version}" ]; then
    printf '%s\n' "${version}"
    return
  fi

  echo "ERROR: ${label} missing from ${manifest_path}. Set CURRENT_MAIN_VERSION/CURRENT_AGENT_VERSION explicitly or regenerate the manifest." >&2
  exit 1
}

latest_remote_tag_version() {
  local repo_dir="$1"
  git -C "${repo_dir}" ls-remote --tags --refs origin 'v*' 2>/dev/null \
    | awk '{sub("refs/tags/", "", $2); print $2}' \
    | grep -E '^v[0-9]+(\.[0-9]+)*$' \
    | sort -V \
    | tail -n 1 \
    | sed 's/^v//'
}

resolve_current_version() {
  local label="$1"
  local repo_dir="$2"
  local remote_version
  remote_version="$(latest_remote_tag_version "${repo_dir}" || true)"
  if [ -n "${remote_version}" ]; then
    printf '%s\n' "${remote_version}"
    return
  fi
  manifest_version "${label}"
}

CURRENT_MAIN_VERSION="${CURRENT_MAIN_VERSION:-$(resolve_current_version "Main Version" "${MAIN_DIR}")}"
CURRENT_AGENT_VERSION="${CURRENT_AGENT_VERSION:-$(resolve_current_version "Agent Version" "${AGENT_DIR}")}"

REUSE_RELEASE_VERSIONS="${REUSE_RELEASE_VERSIONS:-0}"
MAIN_COMMIT="${MAIN_COMMIT:-$(git -C "${MAIN_DIR}" rev-parse HEAD)}"
AGENT_COMMIT="${AGENT_COMMIT:-$(git -C "${AGENT_DIR}" rev-parse HEAD)}"
WEB_COMMIT="${WEB_COMMIT:-$(git -C "${WEB_DIR}" rev-parse HEAD)}"

resolve_remote_tag_commit() {
  local repo_dir="$1"
  local tag="$2"
  local refs
  refs="$(git -C "${repo_dir}" ls-remote origin "refs/tags/${tag}" "refs/tags/${tag}^{}" 2>/dev/null || true)"
  printf '%s\n' "${refs}" | awk '
    /\^\{\}$/ { peeled = $1 }
    !/\^\{\}$/ { direct = $1 }
    END { if (peeled != "") print peeled; else print direct }
  '
}

CURRENT_AGENT_COMMIT="${CURRENT_AGENT_COMMIT:-$(resolve_remote_tag_commit "${AGENT_DIR}" "v${CURRENT_AGENT_VERSION}")}"
VERSION_PLAN_LIB="${SCRIPT_DIR}/release-version-plan.sh"
if [ ! -f "${VERSION_PLAN_LIB}" ]; then
  echo "ERROR: release version planner not found: ${VERSION_PLAN_LIB}" >&2
  exit 1
fi
# shellcheck source=release-version-plan.sh
# The validated path is selected at runtime.
# shellcheck disable=SC1091
source "${VERSION_PLAN_LIB}"
resolve_release_version_plan \
  "${CURRENT_MAIN_VERSION}" \
  "${CURRENT_AGENT_VERSION}" \
  "${AGENT_COMMIT}" \
  "${CURRENT_AGENT_COMMIT}" \
  "${REUSE_RELEASE_VERSIONS}" \
  "${MAIN_VERSION:-}" \
  "${AGENT_VERSION:-}" \
  "${FORCE_AGENT_RELEASE:-0}"

validate_release_version() {
  local label="$1"
  local version="$2"
  if [[ ! "${version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: ${label} must be an exact semantic version such as v1.2.3; got '${version}'" >&2
    exit 1
  fi
}
validate_release_version "MAIN_VERSION" "${MAIN_VERSION}"
validate_release_version "AGENT_VERSION" "${AGENT_VERSION}"

MAIN_VERSION_LDFLAGS="${MAIN_VERSION#v}"
AGENT_VERSION_LDFLAGS="${AGENT_VERSION#v}"

# PUBLIC_AGENT_TAG 是 agent 那条版本线在**公开镜像仓库**里的 tag，带 agent- 前缀。
#
# 公开镜像同时承载主控和 agent 两条独立递增的版本线。此前两条线都用裸 v<x.y.z>
# 打 tag，而它们各自 patch+1、间隔恒定，所以 agent 迟早会撞上若干次之前主控用过的
# tag（当前 main v0.1.36 / agent v0.1.12，间隔 24 → 第 25 次发版必撞）。撞上时
# release 已存在 → 发布中止，而两个私有仓库那时已经发出去了。
# 加前缀让两条线各自占用互不相交的 tag 命名空间，冲突在结构上不再可能发生。
# 私有仓库仍用裸 v<x.y.z>（那里只有一条线），latest_remote_tag_version 也只读私有
# 仓库的 v* tag，不受影响。agent 侧的对应实现见 update/update.go 的 agentMirrorTag。
# review-2026-07-27 H-2
PUBLIC_AGENT_TAG="agent-${AGENT_VERSION}"
MAIN_GIT_HASH="${MAIN_GIT_HASH:-$(git -C "${MAIN_DIR}" rev-parse --short HEAD)}"
PUBLISH_RELEASES="${PUBLISH_RELEASES:-1}"
ALLOW_RELEASE_CLOBBER="${ALLOW_RELEASE_CLOBBER:-0}"
RELEASE_BUILD_ONLY="${RELEASE_BUILD_ONLY:-0}"

if [ "${RELEASE_BUILD_ONLY}" = "1" ] && [ "${PUBLISH_RELEASES}" = "1" ]; then
  echo "ERROR: RELEASE_BUILD_ONLY=1 cannot publish releases." >&2
  exit 1
fi

if [ "${REUSE_RELEASE_VERSIONS}" != "0" ] || [ "${ALLOW_RELEASE_CLOBBER}" != "0" ]; then
  echo "ERROR: release version reuse and asset clobber are no longer supported; publish a new monotonically increasing version." >&2
  exit 1
fi
if [ "${PUBLISH_RELEASES}" = "1" ]; then
  if [ "${MAIN_VERSION}" = "v${CURRENT_MAIN_VERSION}" ]; then
    echo "ERROR: publishing the current main version is forbidden; choose a higher version." >&2
    exit 1
  fi
  if [ "${AGENT_RELEASE_REQUIRED}" = "1" ] && [ "${AGENT_VERSION}" = "v${CURRENT_AGENT_VERSION}" ]; then
    echo "ERROR: republishing the current agent version is forbidden; choose a higher version." >&2
    exit 1
  fi
fi

validate_git_cleanliness() {
  local repo_dir="$1"
  local repo_label="$2"

  if [ ! -d "${repo_dir}/.git" ]; then
    echo "ERROR: ${repo_label} is not a git repository: ${repo_dir}" >&2
    exit 1
  fi

  if [ "${PUBLISH_RELEASES}" != "1" ]; then
    return
  fi

  if ! git -C "${repo_dir}" diff --quiet --ignore-submodules --; then
    echo "ERROR: ${repo_label} has unstaged changes. Commit or stash before release." >&2
    exit 1
  fi

  if ! git -C "${repo_dir}" diff --cached --quiet --ignore-submodules --; then
    echo "ERROR: ${repo_label} has staged but uncommitted changes. Commit or stash before release." >&2
    exit 1
  fi

  if [ -n "$(git -C "${repo_dir}" ls-files --others --exclude-standard)" ]; then
    echo "ERROR: ${repo_label} has untracked files. Commit, stash, or clean before release." >&2
    exit 1
  fi
}

MAIN_TARGETS=(
  "linux amd64"
  "linux arm64"
)

load_agent_targets() {
  if [ ! -f "${AGENT_TARGET_MANIFEST}" ]; then
    echo "ERROR: Agent target manifest is missing: ${AGENT_TARGET_MANIFEST}" >&2
    exit 1
  fi

  AGENT_TARGETS=()
  local schema goos goarch filename ci publish installer self_update
  local target_header
  IFS= read -r target_header < "${AGENT_TARGET_MANIFEST}"
  if [ "${target_header}" != $'schema\tos\tarch\tfilename\tci\tpublish\tinstaller\tself_update' ]; then
    echo "ERROR: invalid Agent target manifest header" >&2
    exit 1
  fi
  while IFS=$'\t' read -r schema goos goarch filename ci publish installer self_update; do
    if [ "${schema}" != "wait-agent-targets/v1" ]; then
      echo "ERROR: invalid Agent target schema: ${schema}" >&2
      exit 1
    fi
    if [[ ! "${goos}" =~ ^[a-z0-9]+$ ]] || [[ ! "${goarch}" =~ ^[a-z0-9]+$ ]] || \
       [[ ! "${filename}" =~ ^[A-Za-z0-9._-]+$ ]]; then
      echo "ERROR: invalid Agent target row: ${goos}/${goarch} ${filename}" >&2
      exit 1
    fi
    if [ "${publish}" = "true" ]; then
      if [ "${ci}" != "true" ] || [ "${self_update}" != "true" ] || [ "${installer}" = "none" ]; then
        echo "ERROR: published Agent target ${goos}/${goarch} lacks ci/installer/self_update" >&2
        exit 1
      fi
      AGENT_TARGETS+=("${goos}|${goarch}|${filename}|${installer}")
    elif [ "${publish}" != "false" ]; then
      echo "ERROR: invalid publish value for Agent target ${goos}/${goarch}: ${publish}" >&2
      exit 1
    fi
  done < <(tail -n +2 "${AGENT_TARGET_MANIFEST}")
  if [ "${#AGENT_TARGETS[@]}" -eq 0 ]; then
    echo "ERROR: Agent target manifest contains no published targets" >&2
    exit 1
  fi
}

# review-2026-08-17 P2-15: every release consumer uses this one manifest.
load_agent_targets
"${AGENT_DIR}/scripts/verify-release-targets.sh" --release-dir "${INSTALLER_DIR}"

validate_git_cleanliness "${MAIN_DIR}" "wait-main"
validate_git_cleanliness "${AGENT_DIR}" "wait-agent-main"
validate_git_cleanliness "${WEB_DIR}" "wait-web-next"

# --target 指向的 commit 必须已经推到远端，否则 GitHub 建不出 tag。
#
# 两个私有仓库的 release 带 --target 且**最先发布**：如果 wait-main 的 commit 没推
# 而 wait-agent-main 的推了，主控 release 直接失败、后面三个一个都发不出去；反过来
# 若 agent 的 commit 没推，主控 release 已经发出去了，剩下三个全挂 —— 半个版本。
# 公开镜像那两个不带 --target，不受这条限制。宁可在开始发布前就拦下来。
# review-2026-07-26 复审 / review-2026-07-27 修正注释里说反的发布顺序
validate_commit_pushed() {
  local repo_dir="$1"
  local label="$2"
  local commit="$3"
  # PUBLISH_RELEASES=0 是文档里明确支持的 dry-run：只构建、不发布，自然也就不需要
  # commit 已经推到远端。与 validate_git_cleanliness 的处理保持一致。
  # review-2026-07-27 low
  if [ "${PUBLISH_RELEASES}" != "1" ]; then
    return
  fi
  if [ "${SKIP_REMOTE_COMMIT_CHECK:-0}" = "1" ]; then
    return
  fi
  # 快路径：刚推上去的 commit 通常就是某个远端分支的 tip，直接用 ls-remote 问远端
  # 真实 refs 命中即可。不能用 git branch -r --contains 做这一步 —— 它看的是本地
  # remote-tracking 引用，push 之后没 fetch，本地引用还停留在旧位置，会把刚推上去的
  # commit 误判成"不在任何远端分支"。review-2026-07-27
  if git -C "${repo_dir}" ls-remote --heads origin 2>/dev/null \
    | awk -v c="${commit}" '$1 == c { found = 1 } END { exit !found }'; then
    return
  fi
  # 不是任何远端分支的 tip（例如推送后远端又前进了）：fetch 一次刷新 remote-tracking
  # 引用，再用本地对象做祖先关系判断。
  git -C "${repo_dir}" fetch --quiet origin
  if [ -z "$(git -C "${repo_dir}" branch -r --contains "${commit}" 2>/dev/null)" ]; then
    echo "ERROR: ${label} HEAD (${commit}) is not present on any remote branch." >&2
    echo "       Push it first, otherwise 'gh release create --target ${commit}' cannot create the tag." >&2
    exit 1
  fi
}
validate_commit_pushed "${MAIN_DIR}" "wait-main" "${MAIN_COMMIT}"
validate_commit_pushed "${AGENT_DIR}" "wait-agent-main" "${AGENT_COMMIT}"
validate_commit_pushed "${WEB_DIR}" "wait-web-next" "${WEB_COMMIT}"

if [ -z "${OUT_DIR}" ] || [ "${OUT_DIR}" = "/" ] || [ "${OUT_DIR}" = "${ROOT_DIR}" ] || [ "${OUT_DIR}" = "${HOME:-}" ]; then
  echo "ERROR: refusing unsafe release output directory: ${OUT_DIR:-<empty>}" >&2
  exit 1
fi
rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}" "${STAGING_ROOT}"
mkdir -p "${MAIN_BUILD_DIR}" "${AGENT_BUILD_DIR}" "${WEB_BUILD_DIR}"

# --- 质量门：发布前强制运行测试与静态分析 ---
# 设置 SKIP_QUALITY_GATE=1 可在紧急情况下绕过（不推荐）。
if [ "${SKIP_QUALITY_GATE:-0}" != "1" ]; then
  printf '\n==> [0/6] Quality gate (go test/vet/staticcheck)\n'

  printf '  wait-main: go vet + go test\n'
  (cd "${MAIN_DIR}" && go vet ./... && go test ./...)

  printf '  wait-agent-main: go vet + go test\n'
  (cd "${AGENT_DIR}" && go vet ./... && go test ./...)

  # staticcheck 可选：未安装则跳过，已安装则强制通过。
  if command -v staticcheck >/dev/null 2>&1; then
    printf '  staticcheck (detected): running on both Go modules\n'
    (cd "${MAIN_DIR}" && staticcheck ./...)
    (cd "${AGENT_DIR}" && staticcheck ./...)
  else
    printf '  staticcheck: not installed, skipped (install with: go install honnef.co/go/tools/cmd/staticcheck@latest)\n'
  fi
else
  printf '\n==> [0/6] Quality gate SKIPPED (SKIP_QUALITY_GATE=1)\n'
fi

printf '\n==> [1/6] Build web dist\n'
if [ "${SKIP_WEB_BUILD:-0}" = "1" ]; then
  printf '  wait-web-next: using prebuilt dist (SKIP_WEB_BUILD=1)\n'
  if [ ! -f "${WEB_DIR}/dist/index.html" ]; then
    echo "ERROR: SKIP_WEB_BUILD=1 but ${WEB_DIR}/dist/index.html is missing" >&2
    exit 1
  fi
else
  npm ci --prefix "${WEB_DIR}"
  if [ "${SKIP_QUALITY_GATE:-0}" != "1" ]; then
    printf '  wait-web-next: lint + unit tests\n'
    npm run lint --prefix "${WEB_DIR}"
    npm run test:unit --prefix "${WEB_DIR}"
  fi
  npm run build --prefix "${WEB_DIR}"
fi

printf '\n==> [2/6] Build wait-main in staging workspace\n'
rm -rf "${MAIN_STAGING_DIR}"
mkdir -p "${MAIN_STAGING_DIR}"
tar -C "${MAIN_DIR}" --exclude='.git' -cf - . | tar -C "${MAIN_STAGING_DIR}" -xf -
rm -rf "${MAIN_THEME_DIST_DIR}"
mkdir -p "$(dirname "${MAIN_THEME_DIST_DIR}")"
cp -R "${WEB_DIR}/dist" "${MAIN_THEME_DIST_DIR}"
cp -R "${WEB_DIR}/dist" "${WEB_BUILD_DIR}/dist"

if [ ! -f "${MAIN_THEME_DIST_DIR}/index.html" ]; then
  echo "ERROR: embedded web index.html missing"
  exit 1
fi

printf '\n==> [3/6] Build wait-main binaries\n'
for target in "${MAIN_TARGETS[@]}"; do
  GOOS="${target%% *}"
  GOARCH="${target##* }"
  BIN_NAME="wait-${GOOS}-${GOARCH}"
  echo "Building ${BIN_NAME}"
  case "${GOARCH}" in
    amd64) ZIG_TARGET="x86_64-linux-musl" ;;
    arm64) ZIG_TARGET="aarch64-linux-musl" ;;
    *) ZIG_TARGET="${GOARCH}-linux-musl" ;;
  esac
  (
    cd "${MAIN_STAGING_DIR}"
    env GOOS="${GOOS}" GOARCH="${GOARCH}" CGO_ENABLED=1 CC="zig cc -target ${ZIG_TARGET}" \
      go build -trimpath -ldflags="-X github.com/wait/wait/utils.CurrentVersion=${MAIN_VERSION_LDFLAGS} -X github.com/wait/wait/utils.VersionHash=${MAIN_GIT_HASH}" -o "${MAIN_BUILD_DIR}/${BIN_NAME}" .
  )
  chmod +x "${MAIN_BUILD_DIR}/${BIN_NAME}"
done

printf '\n==> [4/6] Build wait-agent binaries\n'
(
  cd "${AGENT_DIR}"
  rm -rf build
  mkdir -p build
  for target in "${AGENT_TARGETS[@]}"; do
    IFS='|' read -r GOOS GOARCH BIN_NAME _installer <<< "$target"
    echo "Building ${BIN_NAME}"
    env GOOS="${GOOS}" GOARCH="${GOARCH}" CGO_ENABLED=0 \
      go build -trimpath -ldflags="-X github.com/wait/wait-agent/update.CurrentVersion=${AGENT_VERSION_LDFLAGS}" -o "./build/${BIN_NAME}" .
  done
)
cp -R "${AGENT_DIR}/build/." "${AGENT_BUILD_DIR}/"

printf '\n==> [5/6] Copy notices and generate manifest\n'
cp "${MAIN_STAGING_DIR}/LICENSE" "${OUT_DIR}/LICENSE.wait-main"
cp "${AGENT_DIR}/LICENSE" "${OUT_DIR}/LICENSE.wait-agent"
cp "${INSTALLER_DIR}/install-wait.sh" "${OUT_DIR}/install-wait.sh"
cp "${INSTALLER_DIR}/install-agent.sh" "${OUT_DIR}/install-agent.sh"
cp "${AGENT_TARGET_MANIFEST}" "${OUT_DIR}/wait-agent-targets.tsv"
[ -f "${MAIN_STAGING_DIR}/NOTICE" ] && cp "${MAIN_STAGING_DIR}/NOTICE" "${OUT_DIR}/NOTICE.wait-main" || true
[ -f "${AGENT_DIR}/NOTICE" ] && cp "${AGENT_DIR}/NOTICE" "${OUT_DIR}/NOTICE.wait-agent" || true
write_go_module_inventory "${MAIN_STAGING_DIR}" "${OUT_DIR}/SBOM.wait-main.go-modules.txt"
write_go_module_inventory "${AGENT_DIR}" "${OUT_DIR}/SBOM.wait-agent.go-modules.txt"
write_npm_inventory "${WEB_DIR}" "${OUT_DIR}/SBOM.wait-web-next.npm.json"
write_provenance_metadata "${OUT_DIR}/PROVENANCE.json"
write_agent_update_manifest "${OUT_DIR}/wait-agent-update.json"

cat > "${OUT_DIR}/MANIFEST.txt" <<EOF
Main Version: ${MAIN_VERSION}
Agent Version: ${AGENT_VERSION}

Artifacts:
- wait-main/: embedded-web server binaries (${MAIN_VERSION})
- wait-agent/: agent binaries (${AGENT_VERSION})
- web/dist/: built frontend dist snapshot
- LICENSE.wait-main
- LICENSE.wait-agent
- NOTICE.wait-main (if present)
- NOTICE.wait-agent (if present)
- SBOM.wait-main.go-modules.txt
- SBOM.wait-agent.go-modules.txt
- SBOM.wait-web-next.npm.json
- PROVENANCE.json
- wait-agent-update.json
- wait-agent-update.json.sig
- wait-agent-targets.tsv
- wait-agent-targets.tsv.sig
- install-wait.sh
- install-agent.sh
- SHA256SUMS.txt
- SHA256SUMS.txt.sig
- RELEASE_PUBKEY.pem
- release signing mode: $([ "${RELEASE_BUILD_ONLY}" = "1" ] && printf '%s' "unsigned-build" || printf '%s' "${RELEASE_SIGNING_MODE}")

Release publish targets:
- canonical wait-monitor release tags and source of truth: ${MAIN_PRIVATE_REPO} (${MAIN_VERSION})
- canonical wait-agent release tags and source of truth: ${AGENT_PRIVATE_REPO} (${AGENT_VERSION})
- public installer + mirrored download channel: ${PUBLIC_RELEASE_REPO} (${MAIN_VERSION}, stays 'latest')
- agent self-update channel: ${PUBLIC_RELEASE_REPO} (${PUBLIC_AGENT_TAG}); agents read
  wait-agent-version.txt (${AGENT_VERSION}) from the latest mirror release and then pin
  the agent-prefixed tag, which cannot collide with any main-line tag in this mirror
- installer overrides:
  - WAIT_MAIN_RELEASE_REPO_URL
  - WAIT_MAIN_RELEASE_VERSION
  - WAIT_AGENT_RELEASE_REPO_URL
  - WAIT_RELEASE_SIGNING_KEY
EOF

# agent 版本指针（review-2026-07-26 P0-6 / review-2026-08-16 P1-4）
#
# 公开镜像仓库里同时躺着两条独立的版本线：主控的 v<MAIN> 和 agent 的 v<AGENT>。
# agent 版本指针：公开镜像里有主控和 agent 两条独立的版本线，"取仓库里最新的
# release"这种判断会让 agent 拿主控的版本号跟自己比——既可能误判"已是最新"，也可能
# 把自身版本跳到主控版本线上。这个指针文件随 latest（主控 tag）发布，让 agent 先确定
# 属于自己那条线的版本，再拼出 agent-<version> 精确取该 release
# （见 update/update.go 的 defaultFetchAgentVersionPointer / agentMirrorTag）。
# 指针只负责定位 agent-prefixed tag。该 tag 内的 wait-agent-update.json 及其
# 签名才是更新授权：它绑定版本、单调序列、仓库、tag、target、文件名、长度和摘要。
# 指针与 manifest 都必须在 SHA256SUMS 计算之前写好，才能被发布闭包覆盖。
printf '%s\n' "${AGENT_VERSION}" > "${OUT_DIR}/wait-agent-version.txt"

if ! cmp -s "${AGENT_TARGET_MANIFEST}" "${OUT_DIR}/wait-agent-targets.tsv"; then
  echo "ERROR: staged Agent target manifest is missing or differs from the source contract" >&2
  exit 1
fi
TARGET_MANIFEST_STAGED=1

assert_staged_agent_target_manifest() {
  local phase="$1"
  if ! cmp -s "${AGENT_TARGET_MANIFEST}" "${OUT_DIR}/wait-agent-targets.tsv"; then
    echo "ERROR: staged Agent target manifest was lost during ${phase}" >&2
    exit 1
  fi
}

SIDE_CAR_TARGETS=()
for target in "${AGENT_TARGETS[@]}"; do
  IFS='|' read -r _goos _goarch filename _installer <<< "$target"
  SIDE_CAR_TARGETS+=("${AGENT_BUILD_DIR}/${filename}")
done
for file_path in "${SIDE_CAR_TARGETS[@]}"; do
  if [ -f "${file_path}" ]; then
    write_sha256_sidecar "${file_path}" "${file_path}.sha256"
  fi
done
assert_staged_agent_target_manifest "Agent sidecar generation"

CHECKSUM_INPUTS=()
rm -f "${OUT_DIR}/SHA256SUMS.txt" "${OUT_DIR}/SHA256SUMS.txt.sig" "${OUT_DIR}/${RELEASE_SIGNING_PUBKEY_ASSET}"
assert_staged_agent_target_manifest "checksum reset"
if [ "${RELEASE_BUILD_ONLY}" != "1" ]; then
  # The key is prepared only after all repository-controlled build hooks and
  # compilers have finished. CI uses RELEASE_BUILD_ONLY=1 and signs in a
  # separate job that never checks out or executes product source.
  # review-2026-08-17 P0-1
  prepare_release_signing_key
  write_release_public_key "${OUT_DIR}/${RELEASE_SIGNING_PUBKEY_ASSET}"
fi
assert_staged_agent_target_manifest "release key preparation"
while IFS= read -r file_path; do
  CHECKSUM_INPUTS+=("${file_path}")
done < <(find "${OUT_DIR}" -path "${OUT_DIR}/.staging" -prune -o -type f ! -name 'SHA256SUMS.txt' ! -name '*.sig' -print | LC_ALL=C sort)
if [ "${#CHECKSUM_INPUTS[@]}" -eq 0 ]; then
  echo "ERROR: no release artifacts found under ${OUT_DIR}; refusing to write an empty SHA256SUMS.txt." >&2
  exit 1
fi
write_sha256sums "${OUT_DIR}/SHA256SUMS.txt" "${CHECKSUM_INPUTS[@]}"
assert_staged_agent_target_manifest "checksum generation"

if [ "${RELEASE_BUILD_ONLY}" != "1" ]; then
  SIGNATURE_TARGETS=(
    "${MAIN_BUILD_DIR}/wait-linux-amd64"
    "${MAIN_BUILD_DIR}/wait-linux-arm64"
    "${OUT_DIR}/install-wait.sh"
    "${OUT_DIR}/install-agent.sh"
    "${OUT_DIR}/wait-agent-update.json"
    "${OUT_DIR}/wait-agent-targets.tsv"
    "${OUT_DIR}/SHA256SUMS.txt"
  )
  for target in "${AGENT_TARGETS[@]}"; do
    IFS='|' read -r _goos _goarch filename _installer <<< "$target"
    SIGNATURE_TARGETS+=("${AGENT_BUILD_DIR}/${filename}")
  done
  for file_path in "${SIGNATURE_TARGETS[@]}"; do
    if [ ! -f "${file_path}" ]; then
      echo "ERROR: required release signature target is missing: ${file_path}" >&2
      exit 1
    fi
    sign_release_asset "${file_path}" "${file_path}.sig"
  done
fi
assert_staged_agent_target_manifest "release signing"

printf '\nRelease output ready: %s\n' "${OUT_DIR}"
printf 'Main binaries: %s\n' "${MAIN_BUILD_DIR}"
printf 'Agent binaries: %s\n' "${AGENT_BUILD_DIR}"
printf 'Web snapshot: %s\n' "${WEB_BUILD_DIR}/dist"
printf 'Version plan: main=%s (%s), agent=%s (%s), publish-agent=%s\n' \
  "${MAIN_VERSION}" "${MAIN_VERSION_REASON}" "${AGENT_VERSION}" "${AGENT_VERSION_REASON}" "${AGENT_RELEASE_REQUIRED}"
printf 'Resolved versions: main=%s agent=%s\n' "${MAIN_VERSION}" "${AGENT_VERSION}"

if [ "${RELEASE_BUILD_ONLY}" = "1" ]; then
  printf '\nUnsigned build complete; signing and publishing are intentionally delegated to isolated jobs.\n'
  exit 0
fi

if [ "${PUBLISH_RELEASES}" != "1" ]; then
  printf '\nSkipping GitHub Release publish because PUBLISH_RELEASES=%s\n' "${PUBLISH_RELEASES}"
  exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "ERROR: gh CLI is required to publish releases"
  exit 1
fi

printf '\n==> [6/6] Publish GitHub Releases\n'

MAIN_ASSETS=(
  "${MAIN_BUILD_DIR}/wait-linux-amd64"
  "${MAIN_BUILD_DIR}/wait-linux-arm64"
  "${MAIN_BUILD_DIR}/wait-linux-amd64.sig"
  "${MAIN_BUILD_DIR}/wait-linux-arm64.sig"
  "${OUT_DIR}/LICENSE.wait-main"
  "${OUT_DIR}/MANIFEST.txt"
  "${OUT_DIR}/SHA256SUMS.txt"
  "${OUT_DIR}/SHA256SUMS.txt.sig"
  "${OUT_DIR}/${RELEASE_SIGNING_PUBKEY_ASSET}"
  "${OUT_DIR}/PROVENANCE.json"
  "${OUT_DIR}/SBOM.wait-main.go-modules.txt"
)
append_asset_if_exists MAIN_ASSETS "${OUT_DIR}/NOTICE.wait-main"

AGENT_ASSETS=(
  "${OUT_DIR}/LICENSE.wait-agent"
  "${OUT_DIR}/MANIFEST.txt"
  "${OUT_DIR}/SHA256SUMS.txt"
  "${OUT_DIR}/SHA256SUMS.txt.sig"
  "${OUT_DIR}/${RELEASE_SIGNING_PUBKEY_ASSET}"
  "${OUT_DIR}/PROVENANCE.json"
  "${OUT_DIR}/SBOM.wait-agent.go-modules.txt"
  "${OUT_DIR}/wait-agent-update.json"
  "${OUT_DIR}/wait-agent-update.json.sig"
  "${OUT_DIR}/wait-agent-targets.tsv"
  "${OUT_DIR}/wait-agent-targets.tsv.sig"
)
for target in "${AGENT_TARGETS[@]}"; do
  IFS='|' read -r _goos _goarch filename _installer <<< "$target"
  AGENT_ASSETS+=(
    "${AGENT_BUILD_DIR}/${filename}"
    "${AGENT_BUILD_DIR}/${filename}.sha256"
    "${AGENT_BUILD_DIR}/${filename}.sig"
  )
done
append_asset_if_exists AGENT_ASSETS "${OUT_DIR}/NOTICE.wait-agent"

PUBLIC_ASSETS=(
  "${MAIN_BUILD_DIR}/wait-linux-amd64#wait-linux-amd64"
  "${MAIN_BUILD_DIR}/wait-linux-amd64.sig#wait-linux-amd64.sig"
  "${MAIN_BUILD_DIR}/wait-linux-arm64#wait-linux-arm64"
  "${MAIN_BUILD_DIR}/wait-linux-arm64.sig#wait-linux-arm64.sig"
  "${OUT_DIR}/LICENSE.wait-main#LICENSE.wait-main"
  "${OUT_DIR}/LICENSE.wait-agent#LICENSE.wait-agent"
  "${OUT_DIR}/MANIFEST.txt#MANIFEST.txt"
  "${OUT_DIR}/SHA256SUMS.txt#SHA256SUMS.txt"
  "${OUT_DIR}/SHA256SUMS.txt.sig#SHA256SUMS.txt.sig"
  "${OUT_DIR}/${RELEASE_SIGNING_PUBKEY_ASSET}#${RELEASE_SIGNING_PUBKEY_ASSET}"
  "${OUT_DIR}/PROVENANCE.json#PROVENANCE.json"
  "${OUT_DIR}/SBOM.wait-main.go-modules.txt#SBOM.wait-main.go-modules.txt"
  "${OUT_DIR}/SBOM.wait-agent.go-modules.txt#SBOM.wait-agent.go-modules.txt"
  "${OUT_DIR}/SBOM.wait-web-next.npm.json#SBOM.wait-web-next.npm.json"
  "${OUT_DIR}/wait-agent-version.txt#wait-agent-version.txt"
  "${OUT_DIR}/wait-agent-update.json#wait-agent-update.json"
  "${OUT_DIR}/wait-agent-update.json.sig#wait-agent-update.json.sig"
  "${OUT_DIR}/wait-agent-targets.tsv#wait-agent-targets.tsv"
  "${OUT_DIR}/wait-agent-targets.tsv.sig#wait-agent-targets.tsv.sig"
  "${OUT_DIR}/install-wait.sh#install-wait.sh"
  "${OUT_DIR}/install-wait.sh.sig#install-wait.sh.sig"
  "${OUT_DIR}/install-agent.sh#install-agent.sh"
  "${OUT_DIR}/install-agent.sh.sig#install-agent.sh.sig"
)
for target in "${AGENT_TARGETS[@]}"; do
  IFS='|' read -r _goos _goarch filename _installer <<< "$target"
  PUBLIC_ASSETS+=(
    "${AGENT_BUILD_DIR}/${filename}#${filename}"
    "${AGENT_BUILD_DIR}/${filename}.sig#${filename}.sig"
    "${AGENT_BUILD_DIR}/${filename}.sha256#${filename}.sha256"
  )
done
append_asset_if_exists PUBLIC_ASSETS "${OUT_DIR}/NOTICE.wait-main" "NOTICE.wait-main"
append_asset_if_exists PUBLIC_ASSETS "${OUT_DIR}/NOTICE.wait-agent" "NOTICE.wait-agent"

# agent 自更新专用的镜像 release（review-2026-07-26 P0-6 / review-2026-07-27 H-2）
#
# 与上面那个主控 tag 的镜像 release 分开：agent 读到版本指针后按 PUBLIC_AGENT_TAG
# （即 agent-${AGENT_VERSION}）精确取这个 release，只需要 agent 二进制与配套的校验材料。
# 主控 tag 的 release 仍然保持 latest（两个安装脚本都靠 latest/download 取资产），
# 所以这里**不**从 PUBLIC_ASSETS 里移除 agent 资产。
PUBLIC_AGENT_ASSETS=(
  "${OUT_DIR}/LICENSE.wait-agent#LICENSE.wait-agent"
  "${OUT_DIR}/SHA256SUMS.txt#SHA256SUMS.txt"
  "${OUT_DIR}/SHA256SUMS.txt.sig#SHA256SUMS.txt.sig"
  "${OUT_DIR}/${RELEASE_SIGNING_PUBKEY_ASSET}#${RELEASE_SIGNING_PUBKEY_ASSET}"
  "${OUT_DIR}/PROVENANCE.json#PROVENANCE.json"
  "${OUT_DIR}/SBOM.wait-agent.go-modules.txt#SBOM.wait-agent.go-modules.txt"
  "${OUT_DIR}/wait-agent-version.txt#wait-agent-version.txt"
  "${OUT_DIR}/wait-agent-update.json#wait-agent-update.json"
  "${OUT_DIR}/wait-agent-update.json.sig#wait-agent-update.json.sig"
  "${OUT_DIR}/wait-agent-targets.tsv#wait-agent-targets.tsv"
  "${OUT_DIR}/wait-agent-targets.tsv.sig#wait-agent-targets.tsv.sig"
)
for target in "${AGENT_TARGETS[@]}"; do
  IFS='|' read -r _goos _goarch filename _installer <<< "$target"
  PUBLIC_AGENT_ASSETS+=(
    "${AGENT_BUILD_DIR}/${filename}#${filename}"
    "${AGENT_BUILD_DIR}/${filename}.sig#${filename}.sig"
    "${AGENT_BUILD_DIR}/${filename}.sha256#${filename}.sha256"
  )
done
append_asset_if_exists PUBLIC_AGENT_ASSETS "${OUT_DIR}/NOTICE.wait-agent" "NOTICE.wait-agent"

MAIN_NOTES="$(cat <<EOF
## Summary
- Embedded latest wait-web-next dist into wait-main
- Built wait-main release binaries for linux/amd64 and linux/arm64
- Included LICENSE, NOTICE, MANIFEST, SHA256SUMS, and provenance metadata for distribution
- Published canonical wait-monitor release to ${MAIN_PRIVATE_REPO}
EOF
)"

AGENT_NOTES="$(cat <<EOF
## Summary
- Built wait-agent release binaries for Linux and Windows (x86 + ARM)
- Included LICENSE, NOTICE, MANIFEST, SHA256SUMS, and provenance metadata for distribution
- Published canonical wait-agent release to ${AGENT_PRIVATE_REPO}
EOF
)"

PUBLIC_NOTES="$(cat <<EOF
## Summary
- wait-monitor ${MAIN_VERSION}: embedded wait-web-next dist, built linux binaries
- wait-agent ${AGENT_VERSION}: built Linux/Windows binaries (x86 + ARM)
- Unified public mirror release for installer consumption
- Includes detached signatures, SHA256SUMS, public verification key, provenance metadata, and dependency inventories
- Canonical tags remain in ${MAIN_PRIVATE_REPO} and ${AGENT_PRIVATE_REPO}
EOF
)"

PUBLIC_AGENT_NOTES="$(cat <<EOF
## Summary
- wait-agent ${AGENT_VERSION}: Linux/Windows binaries (x86 + ARM)
- This release exists so deployed agents can resolve their own version line: the agent
  reads wait-agent-version.txt (${AGENT_VERSION}) from the latest mirror release and then
  pins the agent-prefixed tag ${PUBLIC_AGENT_TAG}.
- The agent- prefix keeps the two version lines in separate tag namespaces, so an agent
  version can never collide with a main version published earlier in this mirror.
- Installer downloads keep using the main-tagged mirror release (${MAIN_VERSION}), which stays latest.
- Canonical agent tags remain in ${AGENT_PRIVATE_REPO} (unprefixed, one line only)
EOF
)"

# 先把 4 个目标槽位全查一遍，任何一个已存在就在发布**之前**中止。
# 顺序与下面的实际发布顺序一致，报错信息指向第一个撞车的槽位。
assert_release_absent "${MAIN_PRIVATE_REPO}" "${MAIN_VERSION}"
if [ "${AGENT_RELEASE_REQUIRED}" = "1" ]; then
  assert_release_absent "${AGENT_PRIVATE_REPO}" "${AGENT_VERSION}"
  assert_release_absent "${PUBLIC_RELEASE_REPO}" "${PUBLIC_AGENT_TAG}"
fi
assert_release_absent "${PUBLIC_RELEASE_REPO}" "${MAIN_VERSION}"

upload_release_assets "${MAIN_PRIVATE_REPO}" "${MAIN_VERSION}" "${MAIN_NOTES}" "${MAIN_COMMIT}" "" "${MAIN_ASSETS[@]}"
if [ "${AGENT_RELEASE_REQUIRED}" = "1" ]; then
  upload_release_assets "${AGENT_PRIVATE_REPO}" "${AGENT_VERSION}" "${AGENT_NOTES}" "${AGENT_COMMIT}" "" "${AGENT_ASSETS[@]}"
fi

# 发布顺序有意义（review-2026-07-26 P0-6）：
# agent tag 的镜像 release 必须先发，主控 tag 的镜像 release 后发，这样 GitHub 的
# /releases/latest 仍然指向主控 tag —— install-wait.sh 与 install-agent.sh 都靠
# latest/download 取资产，主控 tag 的 release 里两边的资产俱全。
# agent 镜像 tag 带 agent- 前缀（PUBLIC_AGENT_TAG），与主控 tag 不共享命名空间，
# 因此无论两条版本线是否相等都照常发布，不再需要"相等就跳过"的特例。
if [ "${AGENT_RELEASE_REQUIRED}" = "1" ]; then
  upload_release_assets "${PUBLIC_RELEASE_REPO}" "${PUBLIC_AGENT_TAG}" "${PUBLIC_AGENT_NOTES}" "" false "${PUBLIC_AGENT_ASSETS[@]}"
fi
upload_release_assets "${PUBLIC_RELEASE_REPO}" "${MAIN_VERSION}" "${PUBLIC_NOTES}" "" true "${PUBLIC_ASSETS[@]}"

printf '\nPublished releases:\n'
printf '  - %s %s\n' "${MAIN_PRIVATE_REPO}" "${MAIN_VERSION}"
if [ "${AGENT_RELEASE_REQUIRED}" = "1" ]; then
  printf '  - %s %s\n' "${AGENT_PRIVATE_REPO}" "${AGENT_VERSION}"
  printf '  - %s %s\n' "${PUBLIC_RELEASE_REPO}" "${PUBLIC_AGENT_TAG}"
else
  printf '  - wait-agent remains at %s (source unchanged)\n' "${AGENT_VERSION}"
fi
printf '  - %s %s\n' "${PUBLIC_RELEASE_REPO}" "${MAIN_VERSION}"
