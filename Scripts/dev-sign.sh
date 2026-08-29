#!/bin/bash
# Re-signs a debug build with the same certificate-backed identity release builds use.
#
# Xcode signs SwiftPM executables ad-hoc (flags=0x20002 adhoc,linker-signed), so their
# designated requirement is a bare cdhash that changes on every build. The Keychain records
# "Always Allow" as that requirement, so the grant dies with the next build and macOS asks
# again. Signing with a certificate produces a stable requirement the grant can match.
#
# Wire this up as an Xcode scheme post-action:
#   Product > Scheme > Edit Scheme > Build > Post-actions > New Run Script Action
#   Provide build settings from: ClaudeUsage
#   "${SRCROOT}/Scripts/dev-sign.sh"
set -euo pipefail

BUNDLE_ID="com.fredrir.ClaudeUsage"
SIGNING_IDENTITY="${CLAUDE_USAGE_SIGNING_IDENTITY:-}"

if [[ $# -ge 1 ]]; then
  TARGET="$1"
elif [[ -n "${BUILT_PRODUCTS_DIR:-}" ]]; then
  TARGET="${BUILT_PRODUCTS_DIR}/${EXECUTABLE_NAME:-ClaudeUsage}"
else
  echo "error: pass a path, or run from Xcode with build settings provided" >&2
  exit 2
fi

if [[ ! -e "${TARGET}" ]]; then
  echo "error: no build product at ${TARGET}" >&2
  exit 1
fi

if [[ -z "${SIGNING_IDENTITY}" ]]; then
  SIGNING_IDENTITY="$(
    security find-identity -v -p codesigning 2>/dev/null |
      awk -F '"' '/"Apple Development:/{ print $2; exit }'
  )"
fi

if [[ -z "${SIGNING_IDENTITY}" ]]; then
  echo "error: no Apple Development codesigning identity found; debug builds stay ad-hoc" >&2
  echo "       the Keychain will keep prompting on every build" >&2
  exit 1
fi

# The identifier must match the release bundle identifier: the Keychain ACL entry pins
# `identifier "com.fredrir.ClaudeUsage"` alongside the certificate.
codesign \
  --force \
  --sign "${SIGNING_IDENTITY}" \
  --identifier "${BUNDLE_ID}" \
  --timestamp=none \
  "${TARGET}"

echo "signed ${TARGET}"
echo "  identity:   ${SIGNING_IDENTITY}"
echo "  identifier: ${BUNDLE_ID}"
