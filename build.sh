#!/bin/bash
# Builds ClaudeUsage.app. No full Xcode required — SwiftPM plus a hand-assembled bundle.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="ClaudeUsage"
BUNDLE_ID="com.fredrir.ClaudeUsage"
BUILD_DIR=".build/release"
APP="${APP_NAME}.app"
INSTALL_DIR="${HOME}/Applications"

echo "==> Building (release)"
swift build -c release --product "${APP_NAME}"

echo "==> Assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BUILD_DIR}/${APP_NAME}" "${APP}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "${APP}/Contents/Info.plist"

echo "==> Signing"
# A stable identifier keeps the Keychain ACL entry matching across rebuilds where possible.
codesign --force --sign - --identifier "${BUNDLE_ID}" "${APP}"

if [[ "${1:-}" == "--no-install" ]]; then
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

echo "==> Done. Launch with:"
echo "    open \"${INSTALL_DIR}/${APP}\""
