#!/bin/bash

# This file is sourced by the release script and workflow; these assignments
# are its public output contract and are consumed by the caller.
# shellcheck disable=SC2034

# Resolve the two independent release lines. wait-main always receives a new
# release because it carries the embedded frontend and the public Latest
# bundle. wait-agent advances only when its selected source commit differs
# from the commit behind the current canonical agent tag.
resolve_release_version_plan() {
  local current_main_version="$1"
  local current_agent_version="$2"
  local selected_agent_commit="$3"
  local current_agent_commit="$4"
  local reuse_versions="${5:-0}"
  local requested_main_version="${6:-}"
  local requested_agent_version="${7:-}"
  local force_agent_release="${8:-0}"

  next_release_version() {
    local version="$1"
    local major minor patch
    IFS='.' read -r major minor patch <<< "${version}"
    printf 'v%s.%s.%s' "${major}" "${minor}" "$((patch + 1))"
  }

  if [ -n "${requested_main_version}" ]; then
    MAIN_VERSION="${requested_main_version}"
    MAIN_VERSION_REASON="explicit"
  elif [ "${reuse_versions}" = "1" ]; then
    MAIN_VERSION="v${current_main_version}"
    MAIN_VERSION_REASON="reuse-current"
  else
    MAIN_VERSION="$(next_release_version "${current_main_version}")"
    MAIN_VERSION_REASON="embedded-app-release"
  fi

  if [ -n "${requested_agent_version}" ]; then
    AGENT_VERSION="${requested_agent_version}"
    AGENT_VERSION_REASON="explicit"
  elif [ "${reuse_versions}" = "1" ]; then
    AGENT_VERSION="v${current_agent_version}"
    AGENT_VERSION_REASON="reuse-current"
  elif [ -n "${current_agent_commit}" ] && [ "${selected_agent_commit}" = "${current_agent_commit}" ]; then
    AGENT_VERSION="v${current_agent_version}"
    AGENT_VERSION_REASON="source-unchanged"
  else
    AGENT_VERSION="$(next_release_version "${current_agent_version}")"
    AGENT_VERSION_REASON="source-changed"
  fi

  AGENT_RELEASE_REQUIRED=0
  if [ "${force_agent_release}" = "1" ] || [ "${reuse_versions}" = "1" ] || [ -n "${requested_agent_version}" ] || [ "${AGENT_VERSION}" != "v${current_agent_version}" ]; then
    AGENT_RELEASE_REQUIRED=1
  fi
}
