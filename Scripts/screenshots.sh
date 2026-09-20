#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

cd "${REPO_ROOT}"

BUILD_BIN_DIR=".build/release"
SCREENSHOT_DIR="docs/screenshots"
CHECK=false

usage() {
  cat <<'EOF'
Usage: Scripts/screenshots.sh [--check]

  (no arguments)  Rewrite docs/screenshots/
  --check         Fail if the committed PNGs are out of date
  -h, --help      Show this help
EOF
}

case "${1:-}" in
"") ;;
--check)
  CHECK=true
  ;;
-h | --help)
  usage
  exit 0
  ;;
*)
  usage_error "unknown option: $1"
  ;;
esac
[[ $# -le 1 ]] || usage_error "too many arguments"

log "Building (release)"
swift build -c release --product "${APP_NAME}"

if [[ "${CHECK}" == true ]]; then
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "${TMP_DIR}"' EXIT

  log "Rendering into ${TMP_DIR}"
  "./${BUILD_BIN_DIR}/${APP_NAME}" --screenshot "${TMP_DIR}"

  log "Comparing against ${SCREENSHOT_DIR}"
  if diff -rq "${SCREENSHOT_DIR}" "${TMP_DIR}"; then
    log "Screenshots are up to date"
  else
    printf 'error: screenshots are stale — run ./Scripts/screenshots.sh\n' >&2
    exit 1
  fi
  exit 0
fi

log "Rendering into ${SCREENSHOT_DIR}"
"./${BUILD_BIN_DIR}/${APP_NAME}" --screenshot "${SCREENSHOT_DIR}"
