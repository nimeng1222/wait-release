#!/bin/bash
set -euo pipefail

# Publish a previously built and isolated-signing-verified release closure.
# This script never receives the release signing key and never builds source.
# review-2026-08-17 P0-1 / P2-1

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${OUT_DIR:-${SCRIPT_DIR}/release-output}"

MAIN_PRIVATE_REPO="nimeng1222/wait-monitor"
AGENT_PRIVATE_REPO="nimeng1222/wait-agent"
PUBLIC_RELEASE_REPO="nimeng1222/wait-release"
TRUSTED_RELEASE_PUBKEY_DER_SHA256="fd23f7753c6f9865adaeed9178ed222fbf1f6e173d89334783dcacb4915c3166"

for command_name in gh jq openssl sha256sum cmp; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "ERROR: ${command_name} is required to publish release output" >&2
    exit 1
  fi
done

if [ ! -d "${OUT_DIR}" ]; then
  echo "ERROR: release output directory not found: ${OUT_DIR}" >&2
  exit 1
fi

TARGET_MANIFEST="${OUT_DIR}/wait-agent-targets.tsv"
if [ ! -f "${TARGET_MANIFEST}" ]; then
  echo "ERROR: Agent target manifest is missing: ${TARGET_MANIFEST}" >&2
  exit 1
fi
AGENT_TARGETS=()
# Bash 3.2 treats an empty array expansion as unbound under set -u. The
# sentinel cannot match a validated target key or filename.
AGENT_TARGET_KEYS=("__sentinel__")
AGENT_TARGET_FILENAMES=("__sentinel__")
array_contains() {
  local needle="$1"
  shift
  local value
  for value in "$@"; do
    if [ "$value" = "$needle" ]; then
      return 0
    fi
  done
  return 1
}
IFS= read -r target_header < "${TARGET_MANIFEST}"
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
  if [ "${ci}" != "true" ] && [ "${ci}" != "false" ]; then
    echo "ERROR: invalid ci value for Agent target ${goos}/${goarch}: ${ci}" >&2
    exit 1
  fi
  if [ "${self_update}" != "true" ] && [ "${self_update}" != "false" ]; then
    echo "ERROR: invalid self_update value for Agent target ${goos}/${goarch}: ${self_update}" >&2
    exit 1
  fi
  if [ "${installer}" != "none" ] && [ "${installer}" != "systemd" ] && [ "${installer}" != "windows-nssm" ]; then
    echo "ERROR: invalid installer for Agent target ${goos}/${goarch}: ${installer}" >&2
    exit 1
  fi
  target_key="${goos}/${goarch}"
  if array_contains "$target_key" "${AGENT_TARGET_KEYS[@]}" || \
     array_contains "$filename" "${AGENT_TARGET_FILENAMES[@]}"; then
    echo "ERROR: duplicate Agent target or filename: ${target_key} ${filename}" >&2
    exit 1
  fi
  AGENT_TARGET_KEYS+=("$target_key")
  AGENT_TARGET_FILENAMES+=("$filename")
  if [ "${publish}" = "true" ]; then
    if [ "${ci}" != "true" ] || [ "${self_update}" != "true" ] || [ "${installer}" = "none" ]; then
      echo "ERROR: published Agent target ${goos}/${goarch} lacks ci/installer/self_update" >&2
      exit 1
    fi
    AGENT_TARGETS+=("${goos}|${goarch}|${filename}|${installer}")
  elif [ "${publish}" != "false" ]; then
    echo "ERROR: invalid publish value for Agent target ${goos}/${goarch}" >&2
    exit 1
  fi
done < <(tail -n +2 "${TARGET_MANIFEST}")
if [ "${#AGENT_TARGETS[@]}" -eq 0 ]; then
  echo "ERROR: Agent target manifest contains no published targets" >&2
  exit 1
fi

required_files=(
  "${OUT_DIR}/PROVENANCE.json"
  "${OUT_DIR}/MANIFEST.txt"
  "${OUT_DIR}/SHA256SUMS.txt"
  "${OUT_DIR}/SHA256SUMS.txt.sig"
  "${OUT_DIR}/RELEASE_PUBKEY.pem"
  "${OUT_DIR}/install-wait.sh"
  "${OUT_DIR}/install-wait.sh.sig"
  "${OUT_DIR}/install-agent.sh"
  "${OUT_DIR}/install-agent.sh.sig"
  "${OUT_DIR}/wait-agent-update.json"
  "${OUT_DIR}/wait-agent-update.json.sig"
  "${TARGET_MANIFEST}"
  "${TARGET_MANIFEST}.sig"
  "${OUT_DIR}/wait-main/wait-linux-amd64"
  "${OUT_DIR}/wait-main/wait-linux-amd64.sig"
  "${OUT_DIR}/wait-main/wait-linux-arm64"
  "${OUT_DIR}/wait-main/wait-linux-arm64.sig"
)
for target in "${AGENT_TARGETS[@]}"; do
  IFS='|' read -r _goos _goarch filename _installer <<< "$target"
  required_files+=(
    "${OUT_DIR}/wait-agent/${filename}"
    "${OUT_DIR}/wait-agent/${filename}.sig"
    "${OUT_DIR}/wait-agent/${filename}.sha256"
  )
done
for file_path in "${required_files[@]}"; do
  if [ ! -f "${file_path}" ]; then
    echo "ERROR: required signed release asset is missing: ${file_path}" >&2
    exit 1
  fi
done

actual_pubkey_hash="$(openssl pkey -pubin -in "${OUT_DIR}/RELEASE_PUBKEY.pem" -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
if [ "${actual_pubkey_hash}" != "${TRUSTED_RELEASE_PUBKEY_DER_SHA256}" ] && [ "${VERIFY_ONLY:-0}" != "1" ]; then
  echo "ERROR: release public key does not match the pinned trust root" >&2
  exit 1
fi

(
  cd "${OUT_DIR}"
  sha256sum -c SHA256SUMS.txt
)

signature_targets=(
  "${OUT_DIR}/wait-main/wait-linux-amd64"
  "${OUT_DIR}/wait-main/wait-linux-arm64"
  "${OUT_DIR}/install-wait.sh"
  "${OUT_DIR}/install-agent.sh"
  "${OUT_DIR}/wait-agent-update.json"
  "${TARGET_MANIFEST}"
  "${OUT_DIR}/SHA256SUMS.txt"
)
for target in "${AGENT_TARGETS[@]}"; do
  IFS='|' read -r _goos _goarch filename _installer <<< "$target"
  signature_targets+=("${OUT_DIR}/wait-agent/${filename}")
done
for file_path in "${signature_targets[@]}"; do
  openssl dgst -sha256 -verify "${OUT_DIR}/RELEASE_PUBKEY.pem" -signature "${file_path}.sig" "${file_path}" >/dev/null
done

main_version="$(jq -er '.versions.wait_main' "${OUT_DIR}/PROVENANCE.json")"
agent_version="$(jq -er '.versions.wait_agent' "${OUT_DIR}/PROVENANCE.json")"
main_commit="$(jq -er '.inputs.wait_main.commit' "${OUT_DIR}/PROVENANCE.json")"
agent_commit="$(jq -er '.inputs.wait_agent.commit' "${OUT_DIR}/PROVENANCE.json")"
agent_release_required="$(jq -r '.release_plan.agent_release_required' "${OUT_DIR}/PROVENANCE.json")"
public_agent_tag="$(jq -er '.release_plan.public_agent_tag' "${OUT_DIR}/PROVENANCE.json")"

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

if [[ ! "${main_version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ ! "${agent_version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "ERROR: provenance contains invalid release versions" >&2
  exit 1
fi
if [[ ! "${main_commit}" =~ ^[0-9a-f]{40}$ ]] || [[ ! "${agent_commit}" =~ ^[0-9a-f]{40}$ ]]; then
  echo "ERROR: provenance contains invalid source commits" >&2
  exit 1
fi
if [ "${agent_release_required}" != "true" ] && [ "${agent_release_required}" != "false" ]; then
  echo "ERROR: provenance release_plan.agent_release_required must be boolean" >&2
  exit 1
fi
if [ "${public_agent_tag}" != "agent-${agent_version}" ]; then
  echo "ERROR: provenance public agent tag does not match the Agent version" >&2
  exit 1
fi
if [ "$(jq -er '.release_routing.canonical_wait_main_repo' "${OUT_DIR}/PROVENANCE.json")" != "${MAIN_PRIVATE_REPO}" ] ||
   [ "$(jq -er '.release_routing.canonical_wait_agent_repo' "${OUT_DIR}/PROVENANCE.json")" != "${AGENT_PRIVATE_REPO}" ] ||
   [ "$(jq -er '.release_routing.public_installer_repo' "${OUT_DIR}/PROVENANCE.json")" != "${PUBLIC_RELEASE_REPO}" ]; then
  echo "ERROR: provenance release routing does not match the fixed repository allowlist" >&2
  exit 1
fi

if ! jq -cS . "${OUT_DIR}/wait-agent-update.json" | cmp -s - "${OUT_DIR}/wait-agent-update.json"; then
  echo "ERROR: Agent update manifest is not canonical compact sorted JSON" >&2
  exit 1
fi
expected_agent_sequence="$(agent_update_sequence "${agent_version}")"
if ! jq -e \
  --arg repository "${PUBLIC_RELEASE_REPO}" \
  --arg schema "wait-agent-update/v1" \
  --argjson sequence "${expected_agent_sequence}" \
  --arg tag "${public_agent_tag}" \
  --arg version "${agent_version}" \
  --argjson target_count "${#AGENT_TARGETS[@]}" '
    (keys == ["repository", "schema", "sequence", "tag", "targets", "version"]) and
    .repository == $repository and
    .schema == $schema and
    .sequence == $sequence and
    .tag == $tag and
    .version == $version and
    (.targets | type == "array" and length == $target_count) and
    ([.targets[].target] | unique | length == $target_count) and
    ([.targets[].filename] | unique | length == $target_count) and
    ([.targets[] | keys == ["filename", "length", "sha256", "target"]] | all)
  ' "${OUT_DIR}/wait-agent-update.json" >/dev/null; then
  echo "ERROR: Agent update manifest metadata does not match the release plan" >&2
  exit 1
fi

expected_targets="$(
  for target in "${AGENT_TARGETS[@]}"; do
    IFS='|' read -r goos goarch filename _installer <<< "$target"
    printf '%s/%s|%s\n' "$goos" "$goarch" "$filename"
  done | LC_ALL=C sort
)"
actual_targets="$(jq -r '.targets[] | [.target, .filename] | join("|")' "${OUT_DIR}/wait-agent-update.json" | LC_ALL=C sort)"
if [ "${actual_targets}" != "${expected_targets}" ]; then
  echo "ERROR: Agent update manifest target set is incomplete or unexpected" >&2
  exit 1
fi
while IFS=$'\t' read -r filename expected_length expected_digest; do
  file_path="${OUT_DIR}/wait-agent/${filename}"
  if [ ! -f "${file_path}" ]; then
    echo "ERROR: Agent update manifest references missing file ${filename}" >&2
    exit 1
  fi
  actual_length="$(wc -c < "${file_path}" | tr -d '[:space:]')"
  actual_digest="$(sha256sum "${file_path}" | awk '{print $1}')"
  if [ "${expected_length}" != "${actual_length}" ] || [ "${expected_digest}" != "${actual_digest}" ]; then
    echo "ERROR: Agent update manifest does not match ${filename}" >&2
    exit 1
  fi
done < <(jq -r '.targets[] | [.filename, (.length | tostring), .sha256] | @tsv' "${OUT_DIR}/wait-agent-update.json")

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
    MAIN_ASSETS) MAIN_ASSETS+=("${value}") ;;
    AGENT_ASSETS) AGENT_ASSETS+=("${value}") ;;
    PUBLIC_ASSETS) PUBLIC_ASSETS+=("${value}") ;;
    PUBLIC_AGENT_ASSETS) PUBLIC_AGENT_ASSETS+=("${value}") ;;
    *)
      echo "ERROR: unsupported asset array ${array_name}" >&2
      exit 1
      ;;
  esac
}

MAIN_ASSETS=(
  "${OUT_DIR}/wait-main/wait-linux-amd64"
  "${OUT_DIR}/wait-main/wait-linux-arm64"
  "${OUT_DIR}/wait-main/wait-linux-amd64.sig"
  "${OUT_DIR}/wait-main/wait-linux-arm64.sig"
  "${OUT_DIR}/LICENSE.wait-main"
  "${OUT_DIR}/MANIFEST.txt"
  "${OUT_DIR}/SHA256SUMS.txt"
  "${OUT_DIR}/SHA256SUMS.txt.sig"
  "${OUT_DIR}/RELEASE_PUBKEY.pem"
  "${OUT_DIR}/PROVENANCE.json"
  "${OUT_DIR}/SBOM.wait-main.go-modules.txt"
)
append_asset_if_exists MAIN_ASSETS "${OUT_DIR}/NOTICE.wait-main"

AGENT_ASSETS=(
  "${OUT_DIR}/LICENSE.wait-agent"
  "${OUT_DIR}/MANIFEST.txt"
  "${OUT_DIR}/SHA256SUMS.txt"
  "${OUT_DIR}/SHA256SUMS.txt.sig"
  "${OUT_DIR}/RELEASE_PUBKEY.pem"
  "${OUT_DIR}/PROVENANCE.json"
  "${OUT_DIR}/SBOM.wait-agent.go-modules.txt"
  "${OUT_DIR}/wait-agent-update.json"
  "${OUT_DIR}/wait-agent-update.json.sig"
  "${TARGET_MANIFEST}"
  "${TARGET_MANIFEST}.sig"
)
for target in "${AGENT_TARGETS[@]}"; do
  IFS='|' read -r _goos _goarch filename _installer <<< "$target"
  AGENT_ASSETS+=(
    "${OUT_DIR}/wait-agent/${filename}"
    "${OUT_DIR}/wait-agent/${filename}.sha256"
    "${OUT_DIR}/wait-agent/${filename}.sig"
  )
done
append_asset_if_exists AGENT_ASSETS "${OUT_DIR}/NOTICE.wait-agent"

PUBLIC_ASSETS=(
  "${OUT_DIR}/wait-main/wait-linux-amd64#wait-linux-amd64"
  "${OUT_DIR}/wait-main/wait-linux-amd64.sig#wait-linux-amd64.sig"
  "${OUT_DIR}/wait-main/wait-linux-arm64#wait-linux-arm64"
  "${OUT_DIR}/wait-main/wait-linux-arm64.sig#wait-linux-arm64.sig"
  "${OUT_DIR}/LICENSE.wait-main#LICENSE.wait-main"
  "${OUT_DIR}/LICENSE.wait-agent#LICENSE.wait-agent"
  "${OUT_DIR}/MANIFEST.txt#MANIFEST.txt"
  "${OUT_DIR}/SHA256SUMS.txt#SHA256SUMS.txt"
  "${OUT_DIR}/SHA256SUMS.txt.sig#SHA256SUMS.txt.sig"
  "${OUT_DIR}/RELEASE_PUBKEY.pem#RELEASE_PUBKEY.pem"
  "${OUT_DIR}/PROVENANCE.json#PROVENANCE.json"
  "${OUT_DIR}/SBOM.wait-main.go-modules.txt#SBOM.wait-main.go-modules.txt"
  "${OUT_DIR}/SBOM.wait-agent.go-modules.txt#SBOM.wait-agent.go-modules.txt"
  "${OUT_DIR}/SBOM.wait-web-next.npm.json#SBOM.wait-web-next.npm.json"
  "${OUT_DIR}/wait-agent-version.txt#wait-agent-version.txt"
  "${OUT_DIR}/wait-agent-update.json#wait-agent-update.json"
  "${OUT_DIR}/wait-agent-update.json.sig#wait-agent-update.json.sig"
  "${TARGET_MANIFEST}#wait-agent-targets.tsv"
  "${TARGET_MANIFEST}.sig#wait-agent-targets.tsv.sig"
  "${OUT_DIR}/install-wait.sh#install-wait.sh"
  "${OUT_DIR}/install-wait.sh.sig#install-wait.sh.sig"
  "${OUT_DIR}/install-agent.sh#install-agent.sh"
  "${OUT_DIR}/install-agent.sh.sig#install-agent.sh.sig"
)
for target in "${AGENT_TARGETS[@]}"; do
  IFS='|' read -r _goos _goarch filename _installer <<< "$target"
  PUBLIC_ASSETS+=(
    "${OUT_DIR}/wait-agent/${filename}#${filename}"
    "${OUT_DIR}/wait-agent/${filename}.sig#${filename}.sig"
    "${OUT_DIR}/wait-agent/${filename}.sha256#${filename}.sha256"
  )
done
append_asset_if_exists PUBLIC_ASSETS "${OUT_DIR}/NOTICE.wait-main" "NOTICE.wait-main"
append_asset_if_exists PUBLIC_ASSETS "${OUT_DIR}/NOTICE.wait-agent" "NOTICE.wait-agent"

PUBLIC_AGENT_ASSETS=(
  "${OUT_DIR}/LICENSE.wait-agent#LICENSE.wait-agent"
  "${OUT_DIR}/SHA256SUMS.txt#SHA256SUMS.txt"
  "${OUT_DIR}/SHA256SUMS.txt.sig#SHA256SUMS.txt.sig"
  "${OUT_DIR}/RELEASE_PUBKEY.pem#RELEASE_PUBKEY.pem"
  "${OUT_DIR}/PROVENANCE.json#PROVENANCE.json"
  "${OUT_DIR}/SBOM.wait-agent.go-modules.txt#SBOM.wait-agent.go-modules.txt"
  "${OUT_DIR}/wait-agent-version.txt#wait-agent-version.txt"
  "${OUT_DIR}/wait-agent-update.json#wait-agent-update.json"
  "${OUT_DIR}/wait-agent-update.json.sig#wait-agent-update.json.sig"
  "${TARGET_MANIFEST}#wait-agent-targets.tsv"
  "${TARGET_MANIFEST}.sig#wait-agent-targets.tsv.sig"
)
for target in "${AGENT_TARGETS[@]}"; do
  IFS='|' read -r _goos _goarch filename _installer <<< "$target"
  PUBLIC_AGENT_ASSETS+=(
    "${OUT_DIR}/wait-agent/${filename}#${filename}"
    "${OUT_DIR}/wait-agent/${filename}.sig#${filename}.sig"
    "${OUT_DIR}/wait-agent/${filename}.sha256#${filename}.sha256"
  )
done
append_asset_if_exists PUBLIC_AGENT_ASSETS "${OUT_DIR}/NOTICE.wait-agent" "NOTICE.wait-agent"

assert_asset_files_exist() {
  local asset_spec file_path
  for asset_spec in "$@"; do
    file_path="${asset_spec%%#*}"
    if [ ! -f "${file_path}" ]; then
      echo "ERROR: release asset is missing: ${file_path}" >&2
      exit 1
    fi
  done
}
assert_asset_files_exist "${MAIN_ASSETS[@]}"
assert_asset_files_exist "${AGENT_ASSETS[@]}"
assert_asset_files_exist "${PUBLIC_ASSETS[@]}"
assert_asset_files_exist "${PUBLIC_AGENT_ASSETS[@]}"

MAIN_NOTES="wait-monitor ${main_version}, built from ${main_commit}. Signed release closure includes provenance, SBOM, checksums, and detached signatures."
AGENT_NOTES="wait-agent ${agent_version}, built from ${agent_commit}. Signed release closure includes provenance, SBOM, checksums, and detached signatures."
PUBLIC_NOTES="Public mirror for wait-monitor ${main_version} and wait-agent ${agent_version}. The main release remains Latest for installer compatibility."
PUBLIC_AGENT_NOTES="Public Agent update line for ${agent_version}. Agents resolve this immutable tag through the signed release closure."

if [ "${VERIFY_ONLY:-0}" = "1" ]; then
  printf 'Verified signed release closure locally: main=%s agent=%s agent-release=%s\n' "${main_version}" "${agent_version}" "${agent_release_required}"
  exit 0
fi

assert_release_absent() {
  local repo="$1"
  local tag="$2"
  if gh release view "${tag}" --repo "${repo}" >/dev/null 2>&1; then
    echo "ERROR: release ${repo}@${tag} already exists; executable assets are immutable" >&2
    exit 1
  fi
}

assert_release_absent "${MAIN_PRIVATE_REPO}" "${main_version}"
if [ "${agent_release_required}" = "true" ]; then
  assert_release_absent "${AGENT_PRIVATE_REPO}" "${agent_version}"
  assert_release_absent "${PUBLIC_RELEASE_REPO}" "${public_agent_tag}"
fi
assert_release_absent "${PUBLIC_RELEASE_REPO}" "${main_version}"

CREATED_RELEASES=()
publish_succeeded=0
cleanup_partial_release() {
  local status=$?
  if [ "${publish_succeeded}" = "1" ]; then
    return
  fi
  if [ "${#CREATED_RELEASES[@]}" -gt 0 ]; then
    echo "Release failed; removing releases created by this run to restore the pre-release state" >&2
  fi
  local i entry repo tag
  for ((i=${#CREATED_RELEASES[@]}-1; i>=0; i--)); do
    entry="${CREATED_RELEASES[$i]}"
    repo="${entry%%|*}"
    tag="${entry#*|}"
    gh release delete "${tag}" --repo "${repo}" --cleanup-tag --yes >/dev/null 2>&1 ||
      echo "WARNING: failed to remove partial release ${repo}@${tag}" >&2
  done
  return "${status}"
}
trap cleanup_partial_release EXIT

create_draft() {
  local repo="$1"
  local tag="$2"
  local target="$3"
  local notes="$4"
  shift 4
  local assets=("$@")
  local target_args=()
  if [ -n "${target}" ]; then
    target_args=(--target "${target}")
  fi
  gh release create "${tag}" "${assets[@]}" --repo "${repo}" --draft --title "Release ${tag}" --notes "${notes}" "${target_args[@]}"
  CREATED_RELEASES+=("${repo}|${tag}")
}

asset_name() {
  local asset_spec="$1"
  if [[ "${asset_spec}" == *#* ]]; then
    printf '%s\n' "${asset_spec#*#}"
  else
    basename "${asset_spec}"
  fi
}

asset_path() {
  printf '%s\n' "${1%%#*}"
}

verify_remote_draft() {
  local repo="$1"
  local tag="$2"
  shift 2
  local assets=("$@")
  local download_dir
  download_dir="$(mktemp -d "${RUNNER_TEMP:-/tmp}/wait-release-verify.XXXXXX")"
  gh release download "${tag}" --repo "${repo}" --dir "${download_dir}"
  local asset_spec expected_path expected_name
  for asset_spec in "${assets[@]}"; do
    expected_path="$(asset_path "${asset_spec}")"
    expected_name="$(asset_name "${asset_spec}")"
    if ! cmp -s "${expected_path}" "${download_dir}/${expected_name}"; then
      echo "ERROR: remote draft asset mismatch for ${repo}@${tag}/${expected_name}" >&2
      rm -rf "${download_dir}"
      return 1
    fi
  done
  local downloaded_count
  downloaded_count="$(find "${download_dir}" -maxdepth 1 -type f | wc -l | tr -d ' ')"
  rm -rf "${download_dir}"
  if [ "${downloaded_count}" -ne "${#assets[@]}" ]; then
    echo "ERROR: remote draft ${repo}@${tag} contains ${downloaded_count} assets, expected ${#assets[@]}" >&2
    return 1
  fi
}

create_draft "${MAIN_PRIVATE_REPO}" "${main_version}" "${main_commit}" "${MAIN_NOTES}" "${MAIN_ASSETS[@]}"
if [ "${agent_release_required}" = "true" ]; then
  create_draft "${AGENT_PRIVATE_REPO}" "${agent_version}" "${agent_commit}" "${AGENT_NOTES}" "${AGENT_ASSETS[@]}"
  create_draft "${PUBLIC_RELEASE_REPO}" "${public_agent_tag}" "" "${PUBLIC_AGENT_NOTES}" "${PUBLIC_AGENT_ASSETS[@]}"
fi
create_draft "${PUBLIC_RELEASE_REPO}" "${main_version}" "" "${PUBLIC_NOTES}" "${PUBLIC_ASSETS[@]}"

verify_remote_draft "${MAIN_PRIVATE_REPO}" "${main_version}" "${MAIN_ASSETS[@]}"
if [ "${agent_release_required}" = "true" ]; then
  verify_remote_draft "${AGENT_PRIVATE_REPO}" "${agent_version}" "${AGENT_ASSETS[@]}"
  verify_remote_draft "${PUBLIC_RELEASE_REPO}" "${public_agent_tag}" "${PUBLIC_AGENT_ASSETS[@]}"
fi
verify_remote_draft "${PUBLIC_RELEASE_REPO}" "${main_version}" "${PUBLIC_ASSETS[@]}"

gh release edit "${main_version}" --repo "${MAIN_PRIVATE_REPO}" --draft=false
if [ "${agent_release_required}" = "true" ]; then
  gh release edit "${agent_version}" --repo "${AGENT_PRIVATE_REPO}" --draft=false
  gh release edit "${public_agent_tag}" --repo "${PUBLIC_RELEASE_REPO}" --draft=false --latest=false
fi
gh release edit "${main_version}" --repo "${PUBLIC_RELEASE_REPO}" --draft=false --latest

publish_succeeded=1
trap - EXIT
printf 'Published verified release closure: main=%s agent=%s agent-release=%s\n' "${main_version}" "${agent_version}" "${agent_release_required}"
