#!/bin/bash
# Builds ClaudeUsage.app with SwiftPM plus a hand-assembled bundle. A one-time Apple
# Development certificate setup gives development builds stable Keychain access.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="ClaudeUsage"
BUNDLE_ID="com.fredrir.ClaudeUsage"
BUILD_DIR=".build/release"
APP="${APP_NAME}.app"
INSTALL_DIR="${HOME}/Applications"
INSTALL=true
SIGNING_IDENTITY="${CLAUDE_USAGE_SIGNING_IDENTITY:-}"
ALLOW_ADHOC=false

usage() {
  cat <<EOF
Usage: ./build.sh [--no-install] [--signing-identity IDENTITY] [--adhoc]

By default, the first Apple Development identity in the Keychain is used.
Signing with the same identity across builds lets Keychain remember Always Allow.

Options:
  --no-install                  Leave ClaudeUsage.app in the repository
  --signing-identity IDENTITY  Use this codesigning identity instead of auto-detecting one
  --adhoc                       Use an unstable ad-hoc signature (Keychain may ask again)
  -h, --help                    Show this help

CLAUDE_USAGE_SIGNING_IDENTITY can also provide the identity.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-install)
      INSTALL=false
      shift
      ;;
    --signing-identity)
      if [[ $# -lt 2 ]]; then
        echo "error: --signing-identity requires a value" >&2
        exit 2
      fi
      SIGNING_IDENTITY="$2"
      shift 2
      ;;
    --adhoc)
      ALLOW_ADHOC=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "${ALLOW_ADHOC}" == true && -n "${SIGNING_IDENTITY}" ]]; then
  echo "error: --adhoc cannot be combined with a signing identity" >&2
  exit 2
fi

if [[ "${ALLOW_ADHOC}" == true ]]; then
  SIGNING_IDENTITY="-"
elif [[ -z "${SIGNING_IDENTITY}" ]]; then
  # A certificate-backed identity gives the app a stable designated requirement. An ad-hoc
  # signature's requirement contains the executable's hash and changes on every rebuild.
  SIGNING_IDENTITY="$(
    security find-identity -v -p codesigning 2>/dev/null |
      awk -F '"' '/"Apple Development:/{ print $2; exit }'
  )"
fi

if [[ -z "${SIGNING_IDENTITY}" ]]; then
  cat >&2 <<'EOF'
error: no Apple Development codesigning identity was found.

EOF
  exit 1
fi

echo "==> Building (release)"
swift build -c release --product "${APP_NAME}"

echo "==> Assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BUILD_DIR}/${APP_NAME}" "${APP}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "${APP}/Contents/Info.plist"

echo "==> Signing"
# The bundle identifier and certificate-backed signing identity together produce a stable
# designated requirement, which is what the Keychain ACL records after Always Allow.
if [[ "${SIGNING_IDENTITY}" == "-" ]]; then
  echo "    warning: ad-hoc signatures change identity after every rebuild" >&2
else
  echo "    identity: ${SIGNING_IDENTITY}"
fi
codesign \
  --force \
  --sign "${SIGNING_IDENTITY}" \
  --identifier "${BUNDLE_ID}" \
  --timestamp=none \
  "${APP}"
codesign --verify --strict "${APP}"

if [[ "${INSTALL}" == false ]]; then
  echo "==> Built ${PWD}/${APP} (not installed)"
  exit 0
fi

echo "==> Installing to ${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}"
if pgrep -x "${APP_NAME}" >/dev/null; then
  echo "    stopping running instance"
  pkill -x "${APP_NAME}" || true
  sleep 1
fi
rm -rf "${INSTALL_DIR:?}/${APP}"
cp -R "${APP}" "${INSTALL_DIR}/"

OTHER_COPIES=()
for candidate in "/Applications/${APP}" "${HOME}/Applications/${APP}"; do
  if [[ "${candidate}" != "${INSTALL_DIR}/${APP}" && -e "${candidate}" ]]; then
    OTHER_COPIES+=("${candidate}")
  fi
done

if [[ ${#OTHER_COPIES[@]} -gt 0 ]]; then
  echo
  echo "warning: another copy of ${APP} is installed elsewhere:" >&2
  for candidate in "${OTHER_COPIES[@]}"; do
    echo "    ${candidate}" >&2
  done
  cat >&2 <<'EOF'

    SMAppService records the bundle that registered it, so login may still start the
    other copy. Two copies polling at once also rotate the same refresh token against
    each other. Remove the stale one:

EOF
  for candidate in "${OTHER_COPIES[@]}"; do
    echo "    rm -rf \"${candidate}\"" >&2
  done
  echo >&2
fi

echo "==> Done. Launch with:"
echo "    open \"${INSTALL_DIR}/${APP}\""
