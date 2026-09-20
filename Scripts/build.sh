#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

load_dotenv
cd "${REPO_ROOT}"

BUILD_BIN_DIR=".build/release"
APP_BUNDLE="${APP_NAME}.app"
INSTALL_DIR="${HOME}/Applications"
OUTPUT_DIR="${REPO_ROOT}/dist"
INSTALL=true
PACKAGE=true
ADHOC=false
SIGNING_IDENTITY="${CLAUDE_USAGE_SIGNING_IDENTITY:-${APPLE_DEVELOPER_ID_APPLICATION:-}}"

usage() {
  cat <<EOF
Usage: Scripts/build.sh [--no-install] [--no-package] [--signing-identity IDENTITY] [--adhoc]

Builds, signs, packages, and installs ${APP_BUNDLE}.

Options:
  --no-install                  Leave ${APP_BUNDLE} in the repository
  --no-package                  Skip the .zip in dist/
  --signing-identity IDENTITY   Use this codesigning identity instead of auto-detecting
  --adhoc                       Use an unstable ad-hoc signature (Keychain may ask again)
  -h, --help                    Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  --no-install)
    INSTALL=false
    shift
    ;;
  --no-package)
    PACKAGE=false
    shift
    ;;
  --signing-identity)
    [[ $# -ge 2 ]] || usage_error "--signing-identity requires a value"
    SIGNING_IDENTITY="$2"
    shift 2
    ;;
  --adhoc)
    ADHOC=true
    shift
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

if [[ "${ADHOC}" == true && -n "${SIGNING_IDENTITY}" ]]; then
  usage_error "--adhoc cannot be combined with a signing identity"
fi

if [[ "${ADHOC}" == true ]]; then
  SIGNING_IDENTITY="-"
elif [[ -z "${SIGNING_IDENTITY}" ]]; then
  SIGNING_IDENTITY="$(find_signing_identity any)"
fi

if [[ -z "${SIGNING_IDENTITY}" ]]; then
  die "no Developer ID Application or Apple Development codesigning identity was found"
fi

require_commands swift codesign ditto plutil

log "Building (release)"
swift build -c release --product "${APP_NAME}"

log "Assembling ${APP_BUNDLE}"
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS" "${APP_BUNDLE}/Contents/Resources"
cp "${BUILD_BIN_DIR}/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "${APP_BUNDLE}/Contents/Info.plist"
if [[ -f "${REPO_ROOT}/.env" ]]; then
  log "Embedding .env into bundle"
  grep -E '^(OPENAI_|CLAUDE_)' "${REPO_ROOT}/.env" >"${APP_BUNDLE}/Contents/Resources/.env" || true
  if [[ ! -s "${APP_BUNDLE}/Contents/Resources/.env" ]]; then
    rm -f "${APP_BUNDLE}/Contents/Resources/.env"
  fi
fi

log "Signing"
if [[ "${SIGNING_IDENTITY}" == "-" ]]; then
  warn "ad-hoc signatures change identity after every rebuild"
else
  note "identity: ${SIGNING_IDENTITY}"
fi
codesign \
  --force \
  --sign "${SIGNING_IDENTITY}" \
  --identifier "${BUNDLE_ID}" \
  --timestamp=none \
  "${APP_BUNDLE}"
codesign --verify --strict "${APP_BUNDLE}"

if [[ "${PACKAGE}" == true ]]; then
  VERSION="$(plutil -extract CFBundleShortVersionString raw "${APP_BUNDLE}/Contents/Info.plist")"
  if [[ -z "${VERSION}" || "${VERSION}" == *[!A-Za-z0-9._-]* ]]; then
    die "CFBundleShortVersionString is not safe for an artifact name: ${VERSION}"
  fi

  ARCHIVE_NAME="${APP_NAME}-${VERSION}-dev.zip"
  log "Packaging ${ARCHIVE_NAME}"
  mkdir -p "${OUTPUT_DIR}"
  rm -f "${OUTPUT_DIR:?}/${ARCHIVE_NAME}"
  ditto -c -k --sequesterRsrc --keepParent "${APP_BUNDLE}" "${OUTPUT_DIR}/${ARCHIVE_NAME}"
  note "${OUTPUT_DIR}/${ARCHIVE_NAME}"
fi

if [[ "${INSTALL}" != true ]]; then
  log "Built ${REPO_ROOT}/${APP_BUNDLE} (not installed)"
  exit 0
fi

log "Installing to ${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}"
if pgrep -x "${APP_NAME}" >/dev/null; then
  note "stopping running instance"
  pkill -x "${APP_NAME}" || true
  sleep 1
fi
rm -rf "${INSTALL_DIR:?}/${APP_BUNDLE}"
cp -R "${APP_BUNDLE}" "${INSTALL_DIR}/"

INSTALLED_PATH="${INSTALL_DIR}/${APP_BUNDLE}"
OTHER_COPIES=()
for candidate in "/Applications/${APP_BUNDLE}" "${HOME}/Applications/${APP_BUNDLE}"; do
  if [[ "${candidate}" != "${INSTALLED_PATH}" && -e "${candidate}" ]]; then
    OTHER_COPIES+=("${candidate}")
  fi
done

if [[ ${#OTHER_COPIES[@]} -gt 0 ]]; then
  warn "another copy of ${APP_BUNDLE} is installed elsewhere:"
  for candidate in "${OTHER_COPIES[@]}"; do
    note "${candidate}"
  done
  cat >&2 <<'EOF'

    Removing stale copies:
EOF
  for candidate in "${OTHER_COPIES[@]}"; do
    note "deleting ${candidate}"
    rm -rf -- "${candidate}"
  done
  printf '\n' >&2
fi

log "Done"
open "${INSTALLED_PATH}"
