#!/bin/bash
# Regenerates the README screenshots. Nothing is captured by hand: the app renders its own
# views offscreen against a pinned fixture and a pinned clock, so the PNGs are byte-identical
# between runs and only change when the UI does.
#
#   ./screenshots.sh            # rewrite docs/screenshots/
#   ./screenshots.sh --check    # fail if the committed PNGs are out of date
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="ClaudeUsage"
OUT="docs/screenshots"
BINARY=".build/release/${APP_NAME}"

echo "==> Building (release)"
swift build -c release --product "${APP_NAME}"

if [[ "${1:-}" == "--check" ]]; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "${TMP}"' EXIT

  echo "==> Rendering into ${TMP}"
  "./${BINARY}" --screenshot "${TMP}"

  echo "==> Comparing against ${OUT}"
  if diff -rq "${OUT}" "${TMP}"; then
    echo "==> Screenshots are up to date"
  else
    echo "==> Screenshots are stale — run ./screenshots.sh" >&2
    exit 1
  fi
  exit 0
fi

echo "==> Rendering into ${OUT}"
"./${BINARY}" --screenshot "${OUT}"
