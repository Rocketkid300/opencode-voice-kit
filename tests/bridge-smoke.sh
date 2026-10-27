#!/usr/bin/env bash
# Smoke-test the local bridge without a microphone, Wayland, or wtype.
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/opencode-voice-bridge.XXXXXX")
BRIDGE_PIDS=()

cleanup() {
  if [ "${#BRIDGE_PIDS[@]}" -gt 0 ]; then
    for pid in "${BRIDGE_PIDS[@]}"; do
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    done
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

free_port() {
  python3 - <<'PY'
import socket

sock = socket.socket()
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
sock.close()
PY
}

start_bridge() {
  local log=$1 port=$2 target=$3 opencode=$4 dry_run=$5
  local args=(--port "$port" --no-focus)
  if [ "$dry_run" = "1" ]; then
    args+=(--dry-run)
  fi
  OPENCODE_VOICE_LOG="$log" \
  OPENCODE_VOICE_TARGET_FILE="$target" \
  OPENCODE_VOICE_OPENCODE="$opencode" \
    python3 "$ROOT/bin/opencode-voice-typer" "${args[@]}" >/dev/null 2>&1 &
  local pid=$!
  BRIDGE_PIDS+=("$pid")

  for _ in $(seq 1 50); do
    if curl -sf -m 1 "http://127.0.0.1:$port/" 2>/dev/null | \
         grep -q '"service": "opencode-voice-typer"'; then
      return 0
    fi
    sleep 0.1
  done
  echo "bridge did not start on port $port" >&2
  cat "$log" >&2 || true
  return 1
}

post() {
  local port=$1 path=$2 body=$3
  curl -sS -o /dev/null -w '%{http_code}' \
    -X POST -H 'content-type: application/json' \
    -d "$body" "http://127.0.0.1:$port$path"
}

make_target() {
  local file=$1 session=$2 expires_offset_ms=$3
  python3 - "$file" "$session" "$expires_offset_ms" <<'PY'
import json
import sys
import time

path, session, offset = sys.argv[1], sys.argv[2], int(sys.argv[3])
now = int(time.time() * 1000)
with open(path, "w", encoding="utf-8") as handle:
    json.dump(
        {
            "version": 1,
            "sessionID": session,
            "title": "bridge routing test",
            "mode": "recording",
            "focused": True,
            "pid": 12345,
            "startedAt": now,
            "updatedAt": now,
            "expiresAt": now + offset,
        },
        handle,
    )
PY
}

# 1. No target: keep the standalone wtype fallback.
LOG1="$TMP/fallback-no-target.log"
TARGET1="$TMP/no-target.json"
PORT1=$(free_port)
start_bridge "$LOG1" "$PORT1" "$TARGET1" "" 1
[ "$(post "$PORT1" /tui/append-prompt '{"text":"bridge smoke test"}')" = "200" ]
[ "$(post "$PORT1" /tui/submit-prompt '{}')" = "200" ]
grep -q "append-prompt (dry-run): 'bridge smoke test'" "$LOG1"
grep -q 'submit-prompt (dry-run)' "$LOG1"

# 2. A stale target must not capture a new dictation.
LOG2="$TMP/fallback-stale-target.log"
TARGET2="$TMP/stale-target.json"
make_target "$TARGET2" "ses_staleTarget123" -5000
PORT2=$(free_port)
start_bridge "$LOG2" "$PORT2" "$TARGET2" "" 1
[ "$(post "$PORT2" /tui/append-prompt '{"text":"stale target test"}')" = "200" ]
[ "$(post "$PORT2" /tui/submit-prompt '{}')" = "200" ]
grep -q "append-prompt (dry-run): 'stale target test'" "$LOG2"
grep -q 'submit-prompt (dry-run)' "$LOG2"
if grep -q 'routed' "$LOG2"; then
  echo "stale target was routed instead of falling back" >&2
  exit 1
fi

# 3. A fresh target goes through the OpenCode CLI, and the helper's follow-up
#    Return is suppressed so it cannot submit another tab.
LOG3="$TMP/routed.log"
TARGET3="$TMP/routed-target.json"
FAKE3="$TMP/fake-opencode-ok"
FAKE_LOG3="$TMP/fake-opencode-ok.log"
cat >"$FAKE3" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$FAKE_LOG3"
echo '{"data":{"id":"msg_route_test"}}'
EOF
chmod 755 "$FAKE3"
make_target "$TARGET3" "ses_routeTarget123" 60000
PORT3=$(free_port)
start_bridge "$LOG3" "$PORT3" "$TARGET3" "$FAKE3" 0
[ "$(post "$PORT3" /tui/append-prompt '{"text":"routed bridge smoke test"}')" = "200" ]
[ "$(post "$PORT3" /tui/submit-prompt '{}')" = "200" ]
grep -q '^POST$' "$FAKE_LOG3"
grep -q '^/api/session/ses_routeTarget123/prompt$' "$FAKE_LOG3"
grep -q '"text": "routed bridge smoke test"' "$FAKE_LOG3"
grep -q 'delivered to ses_routeTarget123' "$LOG3"
grep -q 'submit suppressed after API delivery (route=api)' "$LOG3"
if grep -q 'typing into' "$LOG3"; then
  echo "routed delivery also typed into a window" >&2
  exit 1
fi

# 4. If a target exists but delivery fails, do not fall back to another chat.
LOG4="$TMP/routed-failure.log"
TARGET4="$TMP/routed-failure-target.json"
FAKE4="$TMP/fake-opencode-fail"
cat >"$FAKE4" <<'EOF'
#!/usr/bin/env bash
echo "session not found" >&2
exit 1
EOF
chmod 755 "$FAKE4"
make_target "$TARGET4" "ses_routeFail456" 60000
PORT4=$(free_port)
start_bridge "$LOG4" "$PORT4" "$TARGET4" "$FAKE4" 0
[ "$(post "$PORT4" /tui/append-prompt '{"text":"must not fall back"}')" = "500" ]
[ "$(post "$PORT4" /tui/submit-prompt '{}')" = "200" ]
grep -q 'delivery to ses_routeFail456 failed: session not found' "$LOG4"
grep -q 'submit suppressed after API delivery (route=api-failed)' "$LOG4"
if grep -q 'typing into' "$LOG4"; then
  echo "failed routed delivery fell back to typing" >&2
  exit 1
fi

echo "bridge smoke test passed"
