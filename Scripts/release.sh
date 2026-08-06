#!/bin/bash
# Build, sign, package, and optionally notarize a Developer ID release.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPOSITORY_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

APP_NAME="ClaudeUsage"
BUNDLE_ID="com.fredrir.ClaudeUsage"
DEPLOYMENT_TARGET="14.0"
INFO_PLIST="${REPOSITORY_ROOT}/Resources/Info.plist"
ENTITLEMENTS="${REPOSITORY_ROOT}/Configuration/ClaudeUsage.release.entitlements"
OUTPUT_DIR="${REPOSITORY_ROOT}/dist"
SIGNING_IDENTITY="${DEVELOPER_ID_APPLICATION:-}"
NOTARY_PROFILE="${NOTARYTOOL_PROFILE:-}"

usage() {
    cat <<'EOF'
Usage: Scripts/release.sh --identity IDENTITY [options]

Builds a Developer ID release with the Hardened Runtime and a secure timestamp.
When a notary profile is supplied, the script notarizes and staples the app before
creating the final zip.

Options:
  --identity IDENTITY       Developer ID Application identity
  --notary-profile PROFILE  notarytool Keychain profile; omit to skip notarization
  --output DIR              Output directory (default: ./dist)
  -h, --help                Show this help

Environment equivalents:
  DEVELOPER_ID_APPLICATION  Signing identity
  NOTARYTOOL_PROFILE        notarytool Keychain profile

Store notarization credentials with `xcrun notarytool store-credentials`.
Never put passwords or App Store Connect private keys in this repository.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --identity)
            if [[ $# -lt 2 ]]; then
                echo "error: --identity requires a value" >&2
                exit 2
            fi
            SIGNING_IDENTITY="$2"
            shift 2
            ;;
        --notary-profile)
            if [[ $# -lt 2 ]]; then
                echo "error: --notary-profile requires a value" >&2
                exit 2
            fi
            NOTARY_PROFILE="$2"
            shift 2
            ;;
        --output)
            if [[ $# -lt 2 ]]; then
                echo "error: --output requires a value" >&2
                exit 2
            fi
            OUTPUT_DIR="$2"
            shift 2
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

if [[ -z "${SIGNING_IDENTITY}" ]]; then
    echo "error: provide a Developer ID Application identity with --identity or DEVELOPER_ID_APPLICATION" >&2
    exit 2
fi

if [[ "${SIGNING_IDENTITY}" != "Developer ID Application:"* ]]; then
    echo "error: production releases require a 'Developer ID Application:' identity" >&2
    exit 2
fi

for command in swift plutil codesign ditto file lipo security xcrun; do
    if ! command -v "${command}" >/dev/null 2>&1; then
        echo "error: required command not found: ${command}" >&2
        exit 1
    fi
done

if [[ -n "${NOTARY_PROFILE}" ]] && ! xcrun --find notarytool >/dev/null 2>&1; then
    echo "error: notarytool is unavailable in the selected Xcode toolchain" >&2
    exit 1
fi

if ! security find-identity -v -p codesigning | grep -F -- "\"${SIGNING_IDENTITY}\"" >/dev/null; then
    echo "error: signing identity is not available in the login Keychain: ${SIGNING_IDENTITY}" >&2
    exit 1
fi

plutil -lint "${INFO_PLIST}" "${ENTITLEMENTS}" >/dev/null

mkdir -p "${OUTPUT_DIR}"
OUTPUT_DIR="$(cd "${OUTPUT_DIR}" && pwd)"
STAGING_DIR="$(mktemp -d "${OUTPUT_DIR}/.release.XXXXXX")"
trap 'rm -rf "${STAGING_DIR}"' EXIT

APP_BUNDLE="${STAGING_DIR}/${APP_NAME}.app"
APP_CONTENTS="${APP_BUNDLE}/Contents"
APP_EXECUTABLE="${APP_CONTENTS}/MacOS/${APP_NAME}"

echo "==> Building universal release executable"
cd "${REPOSITORY_ROOT}"
SWIFT_BINARIES=()
for architecture in arm64 x86_64; do
    scratch_path="${STAGING_DIR}/build-${architecture}"
    target_triple="${architecture}-apple-macosx${DEPLOYMENT_TARGET}"

    echo "    ${architecture}"
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

echo "==> Assembling fresh app bundle"
mkdir -p "${APP_CONTENTS}/MacOS" "${APP_CONTENTS}/Resources"
lipo -create "${SWIFT_BINARIES[@]}" -output "${APP_EXECUTABLE}"
lipo "${APP_EXECUTABLE}" -verify_arch arm64 x86_64
cp "${INFO_PLIST}" "${APP_CONTENTS}/Info.plist"
chmod 755 "${APP_EXECUTABLE}"

sign_path() {
    local path="$1"
    codesign \
        --force \
        --sign "${SIGNING_IDENTITY}" \
        --options runtime \
        --timestamp \
        "${path}"
}

echo "==> Signing nested code inside out"
while IFS= read -r -d '' candidate; do
    if [[ "${candidate}" == "${APP_EXECUTABLE}" ]]; then
        continue
    fi
    if file -b "${candidate}" | grep -q 'Mach-O'; then
        sign_path "${candidate}"
    fi
done < <(find "${APP_CONTENTS}" -type f -print0)

# Deeper bundle paths sort before their containers. Nested components are signed
# without the main app's entitlements; any future helper-specific entitlement must
# be handled explicitly instead of using codesign --deep.
NESTED_BUNDLES=()
while IFS= read -r -d '' bundle; do
    NESTED_BUNDLES+=("${bundle}")
done < <(
    find "${APP_CONTENTS}" -type d \
        \( -name '*.framework' -o -name '*.xpc' -o -name '*.appex' -o -name '*.app' \) \
    -print0
)

path_depth() {
    local path="$1"
    local depth=0

    while [[ "${path}" == */* ]]; do
        path="${path#*/}"
        depth=$((depth + 1))
    done

    printf '%s' "${depth}"
}

if [[ ${#NESTED_BUNDLES[@]} -gt 1 ]]; then
    for ((outer = 0; outer < ${#NESTED_BUNDLES[@]} - 1; outer++)); do
        for ((inner = outer + 1; inner < ${#NESTED_BUNDLES[@]}; inner++)); do
            outer_depth="$(path_depth "${NESTED_BUNDLES[outer]}")"
            inner_depth="$(path_depth "${NESTED_BUNDLES[inner]}")"
            if [[ ${inner_depth} -gt ${outer_depth} ]]; then
                temporary="${NESTED_BUNDLES[outer]}"
                NESTED_BUNDLES[outer]="${NESTED_BUNDLES[inner]}"
                NESTED_BUNDLES[inner]="${temporary}"
            fi
        done
    done
fi

for bundle in "${NESTED_BUNDLES[@]}"; do
    sign_path "${bundle}"
done

echo "==> Signing app with release entitlements"
codesign \
    --force \
    --sign "${SIGNING_IDENTITY}" \
    --identifier "${BUNDLE_ID}" \
    --options runtime \
    --timestamp \
    --entitlements "${ENTITLEMENTS}" \
    "${APP_BUNDLE}"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"
codesign --display --verbose=2 --entitlements :- "${APP_BUNDLE}"

VERSION="$(plutil -extract CFBundleShortVersionString raw "${APP_CONTENTS}/Info.plist")"
if [[ -z "${VERSION}" || "${VERSION}" == *[!A-Za-z0-9._-]* ]]; then
    echo "error: CFBundleShortVersionString is not safe for an artifact name: ${VERSION}" >&2
    exit 1
fi
ARCHIVE_NAME="${APP_NAME}-${VERSION}.zip"
STAGED_ARCHIVE="${STAGING_DIR}/${ARCHIVE_NAME}"

echo "==> Packaging ${ARCHIVE_NAME} with ditto"
ditto -c -k --sequesterRsrc --keepParent "${APP_BUNDLE}" "${STAGED_ARCHIVE}"

if [[ -n "${NOTARY_PROFILE}" ]]; then
    NOTARY_RESULT="${STAGING_DIR}/notary-result.json"

    echo "==> Submitting for notarization"
    xcrun notarytool submit "${STAGED_ARCHIVE}" \
        --keychain-profile "${NOTARY_PROFILE}" \
        --wait \
        --output-format json > "${NOTARY_RESULT}"

    NOTARY_STATUS="$(plutil -extract status raw "${NOTARY_RESULT}")"
    NOTARY_ID="$(plutil -extract id raw "${NOTARY_RESULT}")"
    xcrun notarytool log "${NOTARY_ID}" \
        --keychain-profile "${NOTARY_PROFILE}" \
        "${STAGING_DIR}/notary-log.json"

    echo "==> Notarization log"
    cat "${STAGING_DIR}/notary-log.json"

    if [[ "${NOTARY_STATUS}" != "Accepted" ]]; then
        echo "error: notarization status was ${NOTARY_STATUS}" >&2
        cat "${STAGING_DIR}/notary-log.json" >&2
        exit 1
    fi

    echo "==> Stapling and validating notarization ticket"
    xcrun stapler staple "${APP_BUNDLE}"
    xcrun stapler validate "${APP_BUNDLE}"

    rm "${STAGED_ARCHIVE}"
    ditto -c -k --sequesterRsrc --keepParent "${APP_BUNDLE}" "${STAGED_ARCHIVE}"
else
    echo "warning: notarization was skipped; do not publish this artifact" >&2
fi

if [[ -n "${NOTARY_PROFILE}" ]]; then
    if command -v syspolicy_check >/dev/null 2>&1; then
        syspolicy_check distribution "${APP_BUNDLE}"
    else
        spctl --assess --type execute --verbose=4 "${APP_BUNDLE}"
    fi
fi

FINAL_APP="${OUTPUT_DIR}/${APP_NAME}.app"
FINAL_ARCHIVE="${OUTPUT_DIR}/${ARCHIVE_NAME}"
if [[ -e "${FINAL_APP}" || -e "${FINAL_ARCHIVE}" ]]; then
    echo "error: release output already exists; move or remove it before retrying" >&2
    echo "       ${FINAL_APP}" >&2
    echo "       ${FINAL_ARCHIVE}" >&2
    exit 1
fi

mv "${APP_BUNDLE}" "${FINAL_APP}"
mv "${STAGED_ARCHIVE}" "${FINAL_ARCHIVE}"

echo "==> Release artifacts"
echo "    ${FINAL_APP}"
echo "    ${FINAL_ARCHIVE}"
