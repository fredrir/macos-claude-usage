#!/bin/bash
# Re-signs a debug build with the same certificate-backed identity release builds use.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

load_dotenv

SIGNING_IDENTITY="${CLAUDE_USAGE_SIGNING_IDENTITY:-${APPLE_DEVELOPER_ID_APPLICATION:-}}"

if [[ $# -ge 1 ]]; then
  TARGET="$1"
elif [[ -n "${BUILT_PRODUCTS_DIR:-}" ]]; then
  TARGET="${BUILT_PRODUCTS_DIR}/${EXECUTABLE_NAME:-${APP_NAME}}"
else
  usage_error "pass a path, or run from Xcode with build settings provided"
fi

[[ -e "${TARGET}" ]] || die "no build product at ${TARGET}"

if [[ -z "${SIGNING_IDENTITY}" ]]; then
  SIGNING_IDENTITY="$(find_signing_identity any)"
fi

if [[ -z "${SIGNING_IDENTITY}" ]]; then
  die "no Developer ID Application or Apple Development codesigning identity found; debug builds stay ad-hoc
       the Keychain will keep prompting on every build"
fi

codesign \
  --force \
  --sign "${SIGNING_IDENTITY}" \
  --identifier "${BUNDLE_ID}" \
  --timestamp=none \
  "${TARGET}"

printf 'signed %s\n' "${TARGET}"
note "identity:   ${SIGNING_IDENTITY}"
note "identifier: ${BUNDLE_ID}"
