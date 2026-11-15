#!/bin/zsh
# Runs the Swift end-to-end sync tests against a throwaway local relay.
# Usage: zsh Scripts/sync-e2e.sh            (local relay on a random port)
#        PASTEHUB_SYNC_TEST_URL=https://... PASTEHUB_SYNC_TEST_KEY=phs1_... zsh Scripts/sync-e2e.sh
set -euo pipefail

cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

if [[ -z "${PASTEHUB_SYNC_TEST_URL:-}" ]]; then
  WORK="$(mktemp -d)"
  trap 'kill ${SERVER_PID:-0} 2>/dev/null; rm -rf "$WORK"' EXIT
  (cd Server && go build -o "$WORK/pastehub-sync" ./cmd/pastehub-sync)
  PORT=$(( 20000 + RANDOM % 20000 ))
  export PASTEHUB_SYNC_TEST_KEY="$("$WORK/pastehub-sync" keygen -data "$WORK/data" -label e2e 2>/dev/null)"
  "$WORK/pastehub-sync" serve -data "$WORK/data" -addr "127.0.0.1:$PORT" 2>"$WORK/server.log" &
  SERVER_PID=$!
  export PASTEHUB_SYNC_TEST_URL="http://127.0.0.1:$PORT"
  for _ in {1..50}; do
    curl -fs "$PASTEHUB_SYNC_TEST_URL/v1/health" >/dev/null 2>&1 && break
    sleep 0.1
  done
fi

swift test --filter 'SyncEndToEndTests'
