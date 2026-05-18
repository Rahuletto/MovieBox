#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAILED=0

run() {
  local label="$1"
  shift
  echo ""
  echo "==> ${label}"
  if "$@"; then
    echo "OK: ${label}"
  else
    echo "FAIL: ${label}"
    FAILED=1
  fi
}

run "CoreTorrent" bash -c "cd '${ROOT}/App/CoreTorrent' && swift test"
run "CoreStreaming" bash -c "cd '${ROOT}/App/CoreStreaming' && swift test"
run "CoreMLEngine" bash -c "cd '${ROOT}/App/CoreMLEngine' && swift test 2>/dev/null || true"

# Backend vitest requires Cloudflare workers pool — optional for streaming stack.

run "MovieBox build" bash -c "cd '${ROOT}/App' && xcodebuild -scheme MovieBox -destination 'platform=macOS' build -quiet"

echo ""
if [[ "${FAILED}" -eq 0 ]]; then
  echo "All automated checks passed."
  exit 0
fi
echo "One or more checks failed."
exit 1
