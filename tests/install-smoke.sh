#!/usr/bin/env bash
# Install into a throwaway HOME, then uninstall, without touching the real one.
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/opencode-voice-install.XXXXXX")
FAKEBIN="$TMP/fakebin"
HOME_DIR="$TMP/home"
BIN_DIR="$HOME_DIR/.local/bin"
export XDG_CONFIG_HOME="$HOME_DIR/.config"
export XDG_DATA_HOME="$HOME_DIR/.local/share"
export XDG_STATE_HOME="$HOME_DIR/.local/state"

cleanup() {
  rm -rf "$TMP"
}
trap cleanup EXIT

mkdir -p "$FAKEBIN" "$HOME_DIR"

# The installer only needs these to be present; the real work is skipped.
cat >"$FAKEBIN/opencode" <<'EOF'
#!/usr/bin/env sh
echo "2.1.4"
EOF
cat >"$FAKEBIN/wtype" <<'EOF'
#!/usr/bin/env sh
exit 0
EOF
cat >"$FAKEBIN/tmux" <<'EOF'
#!/usr/bin/env sh
exit 0
EOF
cat >"$FAKEBIN/systemctl" <<'EOF'
#!/usr/bin/env sh
exit 0
EOF
chmod 755 "$FAKEBIN/opencode" "$FAKEBIN/wtype" "$FAKEBIN/tmux" "$FAKEBIN/systemctl"

run_install() {
  PATH="$FAKEBIN:$PATH" HOME="$HOME_DIR" \
    OPENCODE_VOICE_BIN_DIR="$BIN_DIR" \
    "$ROOT/install.sh" --skip-voice --skip-model --yes "$@"
}

for run in 1 2; do
  log="$TMP/install-$run.log"
  if ! run_install >"$log" 2>&1; then
    cat "$log" >&2
    exit 1
  fi
done  # the second run must not create a pointless plugin backup

for file in opencode-voice-helper opencode-voice-typer ocvoice opencode-with-voice; do
  [ -x "$BIN_DIR/$file" ] || {
    echo "missing executable: $BIN_DIR/$file" >&2
    exit 1
  }
done

for file in index.ts tui.tsx; do
  [ -f "$HOME_DIR/.config/opencode/plugins/voice/$file" ] || {
    echo "missing plugin file: $file" >&2
    exit 1
  }
done

for entry in opencode-voice.desktop voice-input.desktop; do
  path="$HOME_DIR/.local/share/applications/$entry"
  [ -f "$path" ] || {
    echo "missing desktop entry: $entry" >&2
    exit 1
  }
  grep -q "Exec=$BIN_DIR/" "$path"
done

if find "$HOME_DIR/.config/opencode" -maxdepth 1 -name 'voice.bak-*' | grep -q .; then
  echo "unexpected plugin backup on an identical reinstall" >&2
  exit 1
fi

# Do not interfere with a live helper on the developer's machine.  CI has no
# helper running, so the uninstall path is covered there.
if pgrep -u "$UID" -f 'opencode-voice --no-handle-prompts' >/dev/null 2>&1; then
  echo "installer smoke test passed (uninstall skipped: live voice is running)"
  exit 0
fi

PATH="$FAKEBIN:$PATH" HOME="$HOME_DIR" \
  OPENCODE_VOICE_BIN_DIR="$BIN_DIR" "$ROOT/uninstall.sh" >/dev/null

[ ! -e "$HOME_DIR/.config/opencode/plugins/voice" ]
[ ! -e "$BIN_DIR/ocvoice" ]
[ ! -e "$HOME_DIR/.local/share/applications/opencode-voice.desktop" ]

echo "installer smoke test passed"
