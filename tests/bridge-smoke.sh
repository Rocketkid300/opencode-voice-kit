#!/usr/bin/env bash
# Smoke-test the local bridge without a microphone, Wayland, or wtype.
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PORT=$((41000 + RANDOM % 10000))
LOG=$(mktemp "${TMPDIR:-/tmp}/opencode-voice-bridge.XXXXXX.log")
BRIDGE_PID=""

cleanup() {
  if [ -n "$BRIDGE_PID" ]; then
    kill "$BRIDGE_PID" 2>/dev/null || true
    wait "$BRIDGE_PID" 2>/dev/null || true
  fi
  rm -f "$LOG"
}
trap cleanup EXIT

OPENCODE_VOICE_LOG="$LOG" python3 "$ROOT/bin/opencode-voice-typer" \
  --port "$PORT" --dry-run --no-focus >/dev/null 2>&1 &
BRIDGE_PID=$!

ready=0
for _ in $(seq 1 50); do
  if curl -sf -m 1 "http://127.0.0.1:$PORT/" 2>/dev/null | \
       grep -q '"service": "opencode-voice-typer"'; then
    ready=1
    break
  fi
  sleep 0.1
done

if [ "$ready" -ne 1 ]; then
  echo "bridge did not start on port $PORT" >&2
  exit 1
fi

curl -sf -X POST -H 'content-type: application/json' \
  -d '{"text":"bridge smoke test"}' \
  "http://127.0.0.1:$PORT/tui/append-prompt" >/dev/null
curl -sf -X POST -H 'content-type: application/json' -d '{}' \
  "http://127.0.0.1:$PORT/tui/submit-prompt" >/dev/null

grep -q "append-prompt (dry-run): 'bridge smoke test'" "$LOG"
grep -q 'submit-prompt (dry-run)' "$LOG"

echo "bridge smoke test passed"
