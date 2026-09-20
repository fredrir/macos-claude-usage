#!/bin/bash

COMMON_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${COMMON_SH_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${SCRIPTS_DIR}/.." && pwd)"

APP_NAME="ClaudeUsage"
BUNDLE_ID="com.fredrir.ClaudeUsage"

log() { printf '==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}
usage_error() {
  printf 'error: %s\n' "$*" >&2
  exit 2
}

load_dotenv() {
  local env_file="${REPO_ROOT}/.env"
  [[ -f "${env_file}" ]] || return 0
  set -a
  source "${env_file}"
  set +a
}

require_commands() {
  local command
  for command in "$@"; do
    command -v "${command}" >/dev/null 2>&1 || die "required command not found: ${command}"
  done
}

list_signing_identities() {
  security find-identity -v -p codesigning 2>/dev/null |
    awk -F '"' 'NF > 1 { print $2 }'
}

find_signing_identity() {
  local required_kind="${1:-any}"
  local identities
  identities="$(list_signing_identities)"

  local prefixes=("Developer ID Application:")
  [[ "${required_kind}" == "developer-id" ]] || prefixes+=("Apple Development:")

  local prefix identity
  for prefix in "${prefixes[@]}"; do
    if [[ -n "${APPLE_TEAM_ID:-}" ]]; then
      while IFS= read -r identity; do
        if [[ "${identity}" == "${prefix}"*"(${APPLE_TEAM_ID})" ]]; then
          printf '%s\n' "${identity}"
          return 0
        fi
      done <<<"${identities}"
    fi
    while IFS= read -r identity; do
      if [[ "${identity}" == "${prefix}"* ]]; then
        printf '%s\n' "${identity}"
        return 0
      fi
    done <<<"${identities}"
  done
}

assert_signing_identity_available() {
  local identity="$1"
  security find-identity -v -p codesigning 2>/dev/null |
    grep -Fq -- "\"${identity}\"" ||
    die "signing identity is not available in the login Keychain: ${identity}"
}
