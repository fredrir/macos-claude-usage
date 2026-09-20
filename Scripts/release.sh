#!/bin/bash
# Build, sign, package, and optionally notarize a Developer ID release.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

load_dotenv

DEPLOYMENT_TARGET="14.0"
INFO_PLIST="${REPO_ROOT}/Resources/Info.plist"
ENTITLEMENTS="${REPO_ROOT}/Configuration/ClaudeUsage.release.entitlements"
OUTPUT_DIR="${REPO_ROOT}/dist"
SIGNING_IDENTITY="${APPLE_DEVELOPER_ID_APPLICATION:-}"
NOTARY_PROFILE="${NOTARYTOOL_PROFILE:-${APPLE_NOTARY_PROFILE:-}}"

usage() {
  cat <<'EOF'
Usage: Scripts/release.sh [--identity IDENTITY] [options]

Options:
  --identity IDENTITY       Developer ID Application identity (default: auto-detected from Keychain)
  --notary-profile PROFILE  notarytool Keychain profile; omit to skip notarization
  --output DIR              Output directory (default: ./dist)
  -h, --help                Show this help

Environment equivalents:
  APPLE_DEVELOPER_ID_APPLICATION  Signing identity
  NOTARYTOOL_PROFILE        notarytool Keychain profile
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  --identity)
    [[ $# -ge 2 ]] || usage_error "--identity requires a value"
    SIGNING_IDENTITY="$2"
    shift 2
    ;;
  --notary-profile)
    [[ $# -ge 2 ]] || usage_error "--notary-profile requires a value"
    NOTARY_PROFILE="$2"
    shift 2
    ;;
  --output)
    [[ $# -ge 2 ]] || usage_error "--output requires a value"
    OUTPUT_DIR="$2"
    shift 2
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    usage_error "unknown option: $1"
    ;;
  esac
done

if [[ -z "${SIGNING_IDENTITY}" ]]; then
  SIGNING_IDENTITY="$(find_signing_identity developer-id)"
  if [[ -n "${SIGNING_IDENTITY}" ]]; then
    log "Using auto-detected Developer ID identity: ${SIGNING_IDENTITY}"
  fi
fi

if [[ -z "${SIGNING_IDENTITY}" ]]; then
  usage_error "provide a Developer ID Application identity with --identity or APPLE_DEVELOPER_ID_APPLICATION, or install your Developer ID certificate in Keychain"
fi

if [[ "${SIGNING_IDENTITY}" != "Developer ID Application:"* ]]; then
  usage_error "production releases require a 'Developer ID Application:' identity (got: ${SIGNING_IDENTITY})"
fi

require_commands swift plutil codesign ditto file lipo security xcrun

if [[ -n "${NOTARY_PROFILE}" ]] && ! xcrun --find notarytool >/dev/null 2>&1; then
  die "notarytool is unavailable in the selected Xcode toolchain"
fi

assert_signing_identity_available "${SIGNING_IDENTITY}"

plutil -lint "${INFO_PLIST}" "${ENTITLEMENTS}" >/dev/null

mkdir -p "${OUTPUT_DIR}"
OUTPUT_DIR="$(cd "${OUTPUT_DIR}" && pwd)"
STAGING_DIR="$(mktemp -d "${OUTPUT_DIR}/.release.XXXXXX")"
trap 'rm -rf "${STAGING_DIR}"' EXIT

APP_BUNDLE="${STAGING_DIR}/${APP_NAME}.app"
APP_CONTENTS="${APP_BUNDLE}/Contents"
APP_EXECUTABLE="${APP_CONTENTS}/MacOS/${APP_NAME}"

log "Building universal release executable"
cd "${REPO_ROOT}"
SWIFT_BINARIES=()
for architecture in arm64 x86_64; do
  scratch_path="${STAGING_DIR}/build-${architecture}"
  target_triple="${architecture}-apple-macosx${DEPLOYMENT_TARGET}"

  note "${architecture}"
  swift build \
    -c release \
    --product "${APP_NAME}" \
    --triple "${target_triple}" \
    --scratch-path "${scratch_path}"
  binary_dir="$(
    swift build \
      -c release \
      --triple "${target_triple}" \
      --scratch-path "${scratch_path}" \
      --show-bin-path
  )"
  SWIFT_BINARIES+=("${binary_dir}/${APP_NAME}")
done

log "Assembling fresh app bundle"
mkdir -p "${APP_CONTENTS}/MacOS" "${APP_CONTENTS}/Resources"
lipo -create "${SWIFT_BINARIES[@]}" -output "${APP_EXECUTABLE}"
for architecture in arm64 x86_64; do
  lipo -verify_arch "${architecture}" "${APP_EXECUTABLE}"
done
cp "${INFO_PLIST}" "${APP_CONTENTS}/Info.plist"
if [[ -f "${REPO_ROOT}/.env" ]]; then
  # Embed runtime service endpoints and client IDs (excluding personal Apple credentials)
  grep -E '^(OPENAI_|CLAUDE_)' "${REPO_ROOT}/.env" >"${APP_CONTENTS}/Resources/.env" || true
  if [[ ! -s "${APP_CONTENTS}/Resources/.env" ]]; then
    rm -f "${APP_CONTENTS}/Resources/.env"
  fi
fi
chmod 755 "${APP_EXECUTABLE}"

sign_path() {
  codesign \
    --force \
    --sign "${SIGNING_IDENTITY}" \
    --options runtime \
    --timestamp \
    "$1"
}

log "Signing nested code inside out"
while IFS= read -r -d '' candidate; do
  [[ "${candidate}" == "${APP_EXECUTABLE}" ]] && continue
  if file -b "${candidate}" | grep -q 'Mach-O'; then
    sign_path "${candidate}"
  fi
done < <(find "${APP_CONTENTS}" -type f -print0)

while IFS= read -r -d '' bundle; do
  sign_path "${bundle}"
done < <(
  find "${APP_CONTENTS}" -depth -type d \
    \( -name '*.framework' -o -name '*.xpc' -o -name '*.appex' -o -name '*.app' \) \
    -print0
)

log "Signing app with release entitlements"
codesign \
  --force \
  --sign "${SIGNING_IDENTITY}" \
  --identifier "${BUNDLE_ID}" \
  --options runtime \
  --timestamp \
  --entitlements "${ENTITLEMENTS}" \
  "${APP_BUNDLE}"

log "Verifying signature"
codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"
codesign --display --verbose=2 --entitlements - --xml "${APP_BUNDLE}"

VERSION="$(plutil -extract CFBundleShortVersionString raw "${APP_CONTENTS}/Info.plist")"
if [[ -z "${VERSION}" || "${VERSION}" == *[!A-Za-z0-9._-]* ]]; then
  die "CFBundleShortVersionString is not safe for an artifact name: ${VERSION}"
fi
ARCHIVE_NAME="${APP_NAME}-${VERSION}.zip"
STAGED_ARCHIVE="${STAGING_DIR}/${ARCHIVE_NAME}"

log "Packaging ${ARCHIVE_NAME} with ditto"
ditto -c -k --sequesterRsrc --keepParent "${APP_BUNDLE}" "${STAGED_ARCHIVE}"

if [[ -n "${NOTARY_PROFILE}" ]]; then
  NOTARY_RESULT="${STAGING_DIR}/notary-result.json"
  NOTARY_LOG="${STAGING_DIR}/notary-log.json"

  log "Submitting for notarization"
  xcrun notarytool submit "${STAGED_ARCHIVE}" \
    --keychain-profile "${NOTARY_PROFILE}" \
    --wait \
    --output-format json >"${NOTARY_RESULT}"

  NOTARY_STATUS="$(plutil -extract status raw "${NOTARY_RESULT}")"
  NOTARY_ID="$(plutil -extract id raw "${NOTARY_RESULT}")"
  xcrun notarytool log "${NOTARY_ID}" \
    --keychain-profile "${NOTARY_PROFILE}" \
    "${NOTARY_LOG}"

  log "Notarization log"
  cat "${NOTARY_LOG}"

  if [[ "${NOTARY_STATUS}" != "Accepted" ]]; then
    printf 'error: notarization status was %s\n' "${NOTARY_STATUS}" >&2
    cat "${NOTARY_LOG}" >&2
    exit 1
  fi

  log "Stapling and validating notarization ticket"
  xcrun stapler staple "${APP_BUNDLE}"
  xcrun stapler validate "${APP_BUNDLE}"

  rm "${STAGED_ARCHIVE}"
  ditto -c -k --sequesterRsrc --keepParent "${APP_BUNDLE}" "${STAGED_ARCHIVE}"

  if command -v syspolicy_check >/dev/null 2>&1; then
    syspolicy_check distribution "${APP_BUNDLE}"
  else
    spctl --assess --type execute --verbose=4 "${APP_BUNDLE}"
  fi
else
  warn "notarization was skipped; do not publish this artifact"
fi

FINAL_APP="${OUTPUT_DIR}/${APP_NAME}.app"
FINAL_ARCHIVE="${OUTPUT_DIR}/${ARCHIVE_NAME}"
if [[ -e "${FINAL_APP}" || -e "${FINAL_ARCHIVE}" ]]; then
  log "Replacing existing release artifacts"
  rm -rf "${FINAL_APP}" "${FINAL_ARCHIVE}"
fi

mv "${APP_BUNDLE}" "${FINAL_APP}"
mv "${STAGED_ARCHIVE}" "${FINAL_ARCHIVE}"

log "Release artifacts"
note "${FINAL_APP}"
note "${FINAL_ARCHIVE}"
