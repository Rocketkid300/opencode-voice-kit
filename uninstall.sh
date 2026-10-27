#!/usr/bin/env bash
# Remove the local OpenCode voice integration.
# Use --purge to also remove the whisper model and uninstall the
# opencode-voice binary.
set -euo pipefail

PURGE=0
for arg in "$@"; do
  case "$arg" in
    --purge) PURGE=1 ;;
    -h|--help)
      echo "Usage: ./uninstall.sh [--purge]"
      exit 0
      ;;
    *)
      echo "error: unknown option: $arg" >&2
      exit 2
      ;;
  esac
done

BIN_DIR="${OPENCODE_VOICE_BIN_DIR:-$HOME/.local/bin}"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"

echo "Stopping voice helper and bridge…"
if [ -x "$BIN_DIR/opencode-voice-helper" ]; then
  "$BIN_DIR/opencode-voice-helper" stop >/dev/null 2>&1 || true
fi
systemctl --user disable --now opencode-voice-typer.service >/dev/null 2>&1 || true
rm -f "$CONFIG_HOME/systemd/user/opencode-voice-typer.service"
systemctl --user daemon-reload >/dev/null 2>&1 || true

echo "Removing plugin and scripts…"
rm -rf "$CONFIG_HOME/opencode/plugins/voice"
rm -f "$BIN_DIR/opencode-voice-helper" \
      "$BIN_DIR/opencode-voice-typer" \
      "$BIN_DIR/ocvoice" \
      "$BIN_DIR/opencode-with-voice"
rm -f "$DATA_HOME/applications/opencode-voice.desktop" \
      "$DATA_HOME/applications/voice-input.desktop"

if [ "$PURGE" -eq 1 ]; then
  echo "Purging binary, model, and logs…"
  if command -v cargo >/dev/null 2>&1; then
    cargo uninstall opencode-voice >/dev/null 2>&1 || true
  fi
  rm -rf "$DATA_HOME/opencode-voice"
  rm -f "${XDG_STATE_HOME:-$HOME/.local/state}/opencode-voice-typer.log"
fi

echo "Done. Restart OpenCode to unload the TUI plugin."
