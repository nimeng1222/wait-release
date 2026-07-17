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
    *)
      echo "ERROR: unsupported asset array ${array_name}" >&2
      exit 1
      ;;
  esac
}

upload_release_assets() {
  local repo="$1"
  local tag="$2"
  local notes="$3"
  shift 3
  local assets=("$@")

  local release_exists=0
  if gh release view "${tag}" --repo "${repo}" >/dev/null 2>&1; then
    release_exists=1
  fi

  if [ "${release_exists}" -eq 0 ]; then
    echo "Creating release ${tag} in ${repo}"
    gh release create "${tag}" "${assets[@]}" --repo "${repo}" --title "Release ${tag}" --notes "${notes}"
    return
  fi

  if [ "${ALLOW_RELEASE_CLOBBER}" != "1" ]; then
    echo "ERROR: release ${tag} already exists in ${repo}. Immutable mode forbids overwriting assets; publish a new version tag." >&2
    exit 1
  fi

  echo "Updating existing release ${tag} in ${repo} with ALLOW_RELEASE_CLOBBER=1"
  gh release upload "${tag}" "${assets[@]}" --repo "${repo}" --clobber
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
  local go_version
  local web_revision
  node_version="$(node -v)"
  npm_version="$(npm -v)"
  go_version="$(go version)"
  if [ -d "${WEB_DIR}/.git" ]; then
    web_revision="$(git -C "${WEB_DIR}" rev-parse --short HEAD 2>/dev/null || true)"
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
      "repo": "workspace",
      "revision": "${web_revision}"
    }
  },
  "toolchain": {
    "go": "${go_version}",
    "node": "${node_version}",
    "npm": "${npm_version}"
  },
  "release_routing": {
    "canonical_wait_main_repo": "${MAIN_PRIVATE_REPO}",
    "canonical_wait_agent_repo": "${AGENT_PRIVATE_REPO}",
    "public_installer_repo": "${PUBLIC_RELEASE_REPO}"
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
  if [ "${RELEASE_SIGNING_MODE}" = "dry-run-temporary" ]; then
    trusted_release_public_key_path "${output_path}"
    return
  fi
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

next_version() {
  local version="$1"
  IFS='.' read -r major minor patch <<< "$version"
  printf 'v%s.%s.%s' "$major" "$minor" "$((patch + 1))"
}

REUSE_RELEASE_VERSIONS="${REUSE_RELEASE_VERSIONS:-0}"
if [ "${REUSE_RELEASE_VERSIONS}" = "1" ]; then
  MAIN_VERSION="${MAIN_VERSION:-v${CURRENT_MAIN_VERSION}}"
  AGENT_VERSION="${AGENT_VERSION:-v${CURRENT_AGENT_VERSION}}"
else
  MAIN_VERSION="${MAIN_VERSION:-$(next_version "${CURRENT_MAIN_VERSION}")}"
  AGENT_VERSION="${AGENT_VERSION:-$(next_version "${CURRENT_AGENT_VERSION}")}"
fi
MAIN_VERSION_LDFLAGS="${MAIN_VERSION#v}"
AGENT_VERSION_LDFLAGS="${AGENT_VERSION#v}"
MAIN_GIT_HASH="${MAIN_GIT_HASH:-$(git -C "${MAIN_DIR}" rev-parse --short HEAD)}"
PUBLISH_RELEASES="${PUBLISH_RELEASES:-1}"
ALLOW_RELEASE_CLOBBER="${ALLOW_RELEASE_CLOBBER:-0}"

prepare_release_signing_key

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

AGENT_TARGETS=(
  "linux amd64"
  "linux arm64"
  "windows amd64"
  "windows arm64"
)

validate_git_cleanliness "${MAIN_DIR}" "wait-main"
validate_git_cleanliness "${AGENT_DIR}" "wait-agent-main"

mkdir -p "${OUT_DIR}" "${STAGING_ROOT}"
rm -rf "${MAIN_BUILD_DIR}" "${AGENT_BUILD_DIR}" "${WEB_BUILD_DIR}" "${OUT_DIR}/.staging"
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
npm ci --prefix "${WEB_DIR}"
if [ "${SKIP_QUALITY_GATE:-0}" != "1" ]; then
  printf '  wait-web-next: lint + unit tests\n'
  npm run lint --prefix "${WEB_DIR}"
  npm run test:unit --prefix "${WEB_DIR}"
fi
npm run build --prefix "${WEB_DIR}"

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
    GOOS="${target%% *}"
    GOARCH="${target##* }"
    BIN_NAME="wait-agent-${GOOS}-${GOARCH}"
    if [ "${GOOS}" = "windows" ]; then
      BIN_NAME="${BIN_NAME}.exe"
    fi
    echo "Building ${BIN_NAME}"
    env GOOS="${GOOS}" GOARCH="${GOARCH}" CGO_ENABLED=0 \
      go build -trimpath -ldflags="-X github.com/wait/wait-agent/update.CurrentVersion=${AGENT_VERSION_LDFLAGS}" -o "./build/${BIN_NAME}" .
  done
)
cp -R "${AGENT_DIR}/build/." "${AGENT_BUILD_DIR}/"

printf '\n==> [5/6] Copy notices and generate manifest\n'
cp "${MAIN_STAGING_DIR}/LICENSE" "${OUT_DIR}/LICENSE.wait-main"
cp "${AGENT_DIR}/LICENSE" "${OUT_DIR}/LICENSE.wait-agent"
[ -f "${MAIN_STAGING_DIR}/NOTICE" ] && cp "${MAIN_STAGING_DIR}/NOTICE" "${OUT_DIR}/NOTICE.wait-main" || true
[ -f "${AGENT_DIR}/NOTICE" ] && cp "${AGENT_DIR}/NOTICE" "${OUT_DIR}/NOTICE.wait-agent" || true
write_go_module_inventory "${MAIN_STAGING_DIR}" "${OUT_DIR}/SBOM.wait-main.go-modules.txt"
write_go_module_inventory "${AGENT_DIR}" "${OUT_DIR}/SBOM.wait-agent.go-modules.txt"
write_npm_inventory "${WEB_DIR}" "${OUT_DIR}/SBOM.wait-web-next.npm.json"
write_provenance_metadata "${OUT_DIR}/PROVENANCE.json"

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
- SHA256SUMS.txt
- SHA256SUMS.txt.sig
- RELEASE_PUBKEY.pem
- release signing mode: ${RELEASE_SIGNING_MODE}

Release publish targets:
- canonical wait-monitor release tags and source of truth: ${MAIN_PRIVATE_REPO} (${MAIN_VERSION})
- canonical wait-agent release tags and source of truth: ${AGENT_PRIVATE_REPO} (${AGENT_VERSION})
- public installer + mirrored download channel: ${PUBLIC_RELEASE_REPO} (${MAIN_VERSION})
- installer overrides:
  - WAIT_MAIN_RELEASE_REPO_URL
  - WAIT_MAIN_RELEASE_VERSION
  - WAIT_AGENT_RELEASE_REPO_URL
  - WAIT_RELEASE_SIGNING_KEY
EOF

CHECKSUM_INPUTS=()
rm -f "${OUT_DIR}/SHA256SUMS.txt" "${OUT_DIR}/SHA256SUMS.txt.sig" "${OUT_DIR}/${RELEASE_SIGNING_PUBKEY_ASSET}"
write_release_public_key "${OUT_DIR}/${RELEASE_SIGNING_PUBKEY_ASSET}"
while IFS= read -r file_path; do
  CHECKSUM_INPUTS+=("${file_path}")
done < <(find "${OUT_DIR}" -path "${OUT_DIR}/.staging" -prune -o -type f ! -name 'SHA256SUMS.txt' ! -name '*.sig' -print | LC_ALL=C sort)
write_sha256sums "${OUT_DIR}/SHA256SUMS.txt" "${CHECKSUM_INPUTS[@]}"

SIGNATURE_TARGETS=(
  "${MAIN_BUILD_DIR}/wait-linux-amd64"
  "${MAIN_BUILD_DIR}/wait-linux-arm64"
  "${AGENT_BUILD_DIR}/wait-agent-linux-amd64"
  "${AGENT_BUILD_DIR}/wait-agent-linux-arm64"
  "${AGENT_BUILD_DIR}/wait-agent-windows-amd64.exe"
  "${AGENT_BUILD_DIR}/wait-agent-windows-arm64.exe"
  "${OUT_DIR}/SHA256SUMS.txt"
)
for file_path in "${SIGNATURE_TARGETS[@]}"; do
  if [ -f "${file_path}" ]; then
    sign_release_asset "${file_path}" "${file_path}.sig"
  fi
done

SIDE_CAR_TARGETS=(
  "${AGENT_BUILD_DIR}/wait-agent-linux-amd64"
  "${AGENT_BUILD_DIR}/wait-agent-linux-arm64"
  "${AGENT_BUILD_DIR}/wait-agent-windows-amd64.exe"
  "${AGENT_BUILD_DIR}/wait-agent-windows-arm64.exe"
)
for file_path in "${SIDE_CAR_TARGETS[@]}"; do
  if [ -f "${file_path}" ]; then
    write_sha256_sidecar "${file_path}" "${file_path}.sha256"
  fi
done

printf '\nRelease output ready: %s\n' "${OUT_DIR}"
printf 'Main binaries: %s\n' "${MAIN_BUILD_DIR}"
printf 'Agent binaries: %s\n' "${AGENT_BUILD_DIR}"
printf 'Web snapshot: %s\n' "${WEB_BUILD_DIR}/dist"
printf 'Version mode: %s\n' "$( [ "${REUSE_RELEASE_VERSIONS}" = "1" ] && printf 'reuse-current' || printf 'next-patch' )"
printf 'Resolved versions: main=%s agent=%s\n' "${MAIN_VERSION}" "${AGENT_VERSION}"

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
  "${AGENT_BUILD_DIR}/wait-agent-linux-amd64"
  "${AGENT_BUILD_DIR}/wait-agent-linux-amd64.sha256"
  "${AGENT_BUILD_DIR}/wait-agent-linux-arm64"
  "${AGENT_BUILD_DIR}/wait-agent-linux-arm64.sha256"
  "${AGENT_BUILD_DIR}/wait-agent-windows-amd64.exe"
  "${AGENT_BUILD_DIR}/wait-agent-windows-amd64.exe.sha256"
  "${AGENT_BUILD_DIR}/wait-agent-windows-arm64.exe"
  "${AGENT_BUILD_DIR}/wait-agent-windows-arm64.exe.sha256"
  "${AGENT_BUILD_DIR}/wait-agent-linux-amd64.sig"
  "${AGENT_BUILD_DIR}/wait-agent-linux-arm64.sig"
  "${AGENT_BUILD_DIR}/wait-agent-windows-amd64.exe.sig"
  "${AGENT_BUILD_DIR}/wait-agent-windows-arm64.exe.sig"
  "${OUT_DIR}/LICENSE.wait-agent"
  "${OUT_DIR}/MANIFEST.txt"
  "${OUT_DIR}/SHA256SUMS.txt"
  "${OUT_DIR}/SHA256SUMS.txt.sig"
  "${OUT_DIR}/${RELEASE_SIGNING_PUBKEY_ASSET}"
  "${OUT_DIR}/PROVENANCE.json"
  "${OUT_DIR}/SBOM.wait-agent.go-modules.txt"
)
append_asset_if_exists AGENT_ASSETS "${OUT_DIR}/NOTICE.wait-agent"

PUBLIC_ASSETS=(
  "${MAIN_BUILD_DIR}/wait-linux-amd64#wait-linux-amd64"
  "${MAIN_BUILD_DIR}/wait-linux-amd64.sig#wait-linux-amd64.sig"
  "${MAIN_BUILD_DIR}/wait-linux-arm64#wait-linux-arm64"
  "${MAIN_BUILD_DIR}/wait-linux-arm64.sig#wait-linux-arm64.sig"
  "${AGENT_BUILD_DIR}/wait-agent-linux-amd64#wait-agent-linux-amd64"
  "${AGENT_BUILD_DIR}/wait-agent-linux-amd64.sig#wait-agent-linux-amd64.sig"
  "${AGENT_BUILD_DIR}/wait-agent-linux-amd64.sha256#wait-agent-linux-amd64.sha256"
  "${AGENT_BUILD_DIR}/wait-agent-linux-arm64#wait-agent-linux-arm64"
  "${AGENT_BUILD_DIR}/wait-agent-linux-arm64.sig#wait-agent-linux-arm64.sig"
  "${AGENT_BUILD_DIR}/wait-agent-linux-arm64.sha256#wait-agent-linux-arm64.sha256"
  "${AGENT_BUILD_DIR}/wait-agent-windows-amd64.exe#wait-agent-windows-amd64.exe"
  "${AGENT_BUILD_DIR}/wait-agent-windows-amd64.exe.sig#wait-agent-windows-amd64.exe.sig"
  "${AGENT_BUILD_DIR}/wait-agent-windows-amd64.exe.sha256#wait-agent-windows-amd64.exe.sha256"
  "${AGENT_BUILD_DIR}/wait-agent-windows-arm64.exe#wait-agent-windows-arm64.exe"
  "${AGENT_BUILD_DIR}/wait-agent-windows-arm64.exe.sig#wait-agent-windows-arm64.exe.sig"
  "${AGENT_BUILD_DIR}/wait-agent-windows-arm64.exe.sha256#wait-agent-windows-arm64.exe.sha256"
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
)
append_asset_if_exists PUBLIC_ASSETS "${OUT_DIR}/NOTICE.wait-main" "NOTICE.wait-main"
append_asset_if_exists PUBLIC_ASSETS "${OUT_DIR}/NOTICE.wait-agent" "NOTICE.wait-agent"

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

upload_release_assets "${MAIN_PRIVATE_REPO}" "${MAIN_VERSION}" "${MAIN_NOTES}" "${MAIN_ASSETS[@]}"
upload_release_assets "${AGENT_PRIVATE_REPO}" "${AGENT_VERSION}" "${AGENT_NOTES}" "${AGENT_ASSETS[@]}"
upload_release_assets "${PUBLIC_RELEASE_REPO}" "${MAIN_VERSION}" "${PUBLIC_NOTES}" "${PUBLIC_ASSETS[@]}"

printf '\nPublished releases:\n'
printf '  - %s %s\n' "${MAIN_PRIVATE_REPO}" "${MAIN_VERSION}"
printf '  - %s %s\n' "${AGENT_PRIVATE_REPO}" "${AGENT_VERSION}"
printf '  - %s %s\n' "${PUBLIC_RELEASE_REPO}" "${MAIN_VERSION}"
