#!/usr/bin/env bash
# Install local push-to-talk voice input for OpenCode on Linux/Wayland.
#
# This installs:
#   ~/.local/bin/opencode-voice-helper
#   ~/.local/bin/opencode-voice-typer
#   ~/.local/bin/ocvoice
#   ~/.local/bin/opencode-with-voice
#   ~/.config/opencode/plugins/voice/{index.ts,tui.tsx}
#   ~/.local/share/applications/opencode-voice.desktop
#   ~/.local/share/applications/voice-input.desktop
#
# and, unless --skip-voice is used, builds the opencode-voice Rust binary and
# downloads the local whisper model.  Nothing is sent to a cloud service.
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

BIN_DIR="${OPENCODE_VOICE_BIN_DIR:-$HOME/.local/bin}"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
PLUGIN_DIR="$CONFIG_HOME/opencode/plugins/voice"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
APPLICATIONS_DIR="$DATA_HOME/applications"
SYSTEMD_DIR="$CONFIG_HOME/systemd/user"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}"
VOICE_STATE_DIR="${OPENCODE_VOICE_STATE_DIR:-$STATE_DIR/opencode-voice}"
VOICE_VERSION="${OPENCODE_VOICE_VERSION:-0.1.4}"
MODEL="${OPENCODE_VOICE_MODEL:-base.en}"

SKIP_VOICE=0
SKIP_MODEL=0
FORCE_VOICE=0
WITH_SYSTEMD=0
ASSUME_YES=0

usage() {
  cat <<'EOF'
Usage: ./install.sh [options]

Options:
  --skip-voice     do not build/install the opencode-voice binary
  --skip-model     do not download the whisper model
  --force-voice    rebuild/reinstall opencode-voice even if it is present
  --with-systemd   install and enable the bridge as a systemd user service
  --yes            assume yes for prompts
  -h, --help       show this help

Environment:
  OPENCODE_VOICE_BIN_DIR   install directory (default: ~/.local/bin)
  OPENCODE_VOICE_MODEL     whisper model (default: base.en)
  OPENCODE_VOICE_VERSION   crate version (default: 0.1.4)
  OPENCODE_VOICE_STATE_DIR routing state directory
EOF
}

for arg in "$@"; do
  case "$arg" in
    --skip-voice) SKIP_VOICE=1 ;;
    --skip-model) SKIP_MODEL=1 ;;
    --force-voice) FORCE_VOICE=1 ;;
    --with-systemd) WITH_SYSTEMD=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown option: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
sed_escape() { printf '%s' "$1" | sed 's/[\\&|]/\\&/g'; }

say "Checking prerequisites"

[ "$(uname -s)" = "Linux" ] || die "This kit currently supports Linux only."
[ -n "${HOME:-}" ] || die "HOME is not set."
[ "$(id -u)" -ne 0 ] || die "Run this as your normal user, not with sudo/root."

command -v opencode >/dev/null 2>&1 || die "OpenCode is not installed. Install OpenCode v2 first."
OPENCODE_VERSION=$(opencode --version 2>/dev/null | head -n 1 || true)
case "$OPENCODE_VERSION" in
  *v2.*|*" 2."*|2.*) ;;
  *) warn "OpenCode v2 was not detected (got: ${OPENCODE_VERSION:-unknown}). The TUI plugin targets v2." ;;
esac

for cmd in tmux python3 wtype curl install; do
  command -v "$cmd" >/dev/null 2>&1 || die "Missing required command: $cmd"
done
command -v jq >/dev/null 2>&1 || \
  warn "jq was not found. The 'OpenCode (with voice)' launcher will open a new TUI instead of focusing an existing one."

if [ "${XDG_SESSION_TYPE:-}" != "wayland" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
  warn "No Wayland session detected. wtype needs a compositor with virtual-keyboard support."
  warn "Hyprland and Sway work; GNOME is not supported by wtype."
fi

if ! id -nG | tr ' ' '\n' | grep -qx input; then
  warn "Your user is not in the 'input' group. Global Right Alt needs evdev access."
  warn "Run: sudo usermod -aG input $USER"
  warn "Then log out and back in (or reboot) before using voice."
fi

VOICE_BIN="${OPENCODE_VOICE_BIN:-$(command -v opencode-voice 2>/dev/null || true)}"
[ -n "$VOICE_BIN" ] || VOICE_BIN="$HOME/.cargo/bin/opencode-voice"

if [ "$SKIP_VOICE" -eq 0 ]; then
  if [ "$FORCE_VOICE" -eq 0 ] && [ -x "$VOICE_BIN" ]; then
    say "opencode-voice already present: $VOICE_BIN"
  else
    command -v cargo >/dev/null 2>&1 || die "Rust/cargo is required to build opencode-voice.
Install Rust from https://rustup.rs, then re-run this installer."
    command -v clang >/dev/null 2>&1 || warn "clang was not found; the whisper.cpp build may fail."
    command -v cmake >/dev/null 2>&1 || warn "cmake was not found; the whisper.cpp build may fail."

    say "Building opencode-voice $VOICE_VERSION (local whisper.cpp, no cloud)"
    say "This can take several minutes the first time."
    WHISPER_DONT_GENERATE_BINDINGS=1 \
      cargo install opencode-voice --version "$VOICE_VERSION" --locked --force

    VOICE_BIN="$HOME/.cargo/bin/opencode-voice"
    [ -x "$VOICE_BIN" ] || VOICE_BIN=$(command -v opencode-voice 2>/dev/null || true)
    [ -x "$VOICE_BIN" ] || die "opencode-voice was installed but could not be found."
  fi
else
  say "Skipping opencode-voice binary installation (--skip-voice)"
fi

if [ "$SKIP_MODEL" -eq 0 ]; then
  [ -x "$VOICE_BIN" ] || die "Cannot download the model: $VOICE_BIN is missing."
  say "Ensuring whisper model '$MODEL' is present (downloaded locally on first run)"
  if [ "$ASSUME_YES" -eq 0 ] && [ -t 0 ]; then
    read -r -p "Download the '$MODEL' model if missing (about 142 MB for base.en)? [Y/n] " answer
    case "${answer:-Y}" in
      [Nn]*) warn "Skipping model download; run '$VOICE_BIN setup --model $MODEL' later." ;;
      *) "$VOICE_BIN" setup --model "$MODEL" ;;
    esac
  else
    "$VOICE_BIN" setup --model "$MODEL"
  fi
else
  say "Skipping model download (--skip-model)"
fi

say "Installing scripts into $BIN_DIR"
install -d "$BIN_DIR" "$PLUGIN_DIR" "$STATE_DIR"
install -d -m 0700 "$VOICE_STATE_DIR"
install -m 0755 "$ROOT/bin/opencode-voice-typer" "$BIN_DIR/"
install -m 0755 "$ROOT/bin/ocvoice" "$BIN_DIR/"
install -m 0755 "$ROOT/bin/opencode-voice-helper" "$BIN_DIR/"
install -m 0755 "$ROOT/bin/opencode-with-voice" "$BIN_DIR/"

plugin_changed=0
for file in index.ts tui.tsx; do
  if [ -f "$PLUGIN_DIR/$file" ] && \
     ! cmp -s "$ROOT/opencode/plugins/voice/$file" "$PLUGIN_DIR/$file"; then
    plugin_changed=1
  fi
done
if [ "$plugin_changed" -eq 1 ]; then
  backup="$PLUGIN_DIR.bak-$(date +%Y%m%d-%H%M%S)"
  cp -a "$PLUGIN_DIR" "$backup"
  say "Backed up existing plugin to $backup"
fi

say "Installing the OpenCode TUI plugin"
install -m 0644 "$ROOT/opencode/plugins/voice/index.ts" "$PLUGIN_DIR/"
install -m 0644 "$ROOT/opencode/plugins/voice/tui.tsx" "$PLUGIN_DIR/"

say "Installing desktop entries"
install -d "$APPLICATIONS_DIR"
BIN_DIR_SED=$(sed_escape "$BIN_DIR")
for template in opencode-voice.desktop.in voice-input.desktop.in; do
  name="${template%.in}"
  sed "s|@BIN_DIR@|$BIN_DIR_SED|g" "$ROOT/desktop/$template" > "$APPLICATIONS_DIR/$name"
  chmod 0644 "$APPLICATIONS_DIR/$name"
  if command -v desktop-file-validate >/dev/null 2>&1; then
    desktop-file-validate "$APPLICATIONS_DIR/$name" || warn "desktop entry validation failed for $name"
  fi
done
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$APPLICATIONS_DIR" >/dev/null 2>&1 || true
fi

if [ "$WITH_SYSTEMD" -eq 1 ]; then
  if command -v systemctl >/dev/null 2>&1; then
    say "Installing the bridge systemd user service"
    install -d "$SYSTEMD_DIR"
    BIN_DIR_SED=$(sed_escape "$BIN_DIR")
    sed "s|@BIN_DIR@|$BIN_DIR_SED|g" "$ROOT/systemd/opencode-voice-typer.service.in" \
      > "$SYSTEMD_DIR/opencode-voice-typer.service"
    systemctl --user daemon-reload
    systemctl --user enable --now opencode-voice-typer.service || \
      warn "Could not start the service; the helper will start the bridge on demand."
  else
    warn "systemctl not found; skipping the optional service."
  fi
fi

if [ "$BIN_DIR" != "$HOME/.local/bin" ] && [ "$BIN_DIR" != "$HOME/bin" ]; then
  warn "The TUI plugin looks in ~/.local/bin and ~/bin."
  warn "Set OPENCODE_VOICE_HELPER=$BIN_DIR/opencode-voice-helper in your environment,"
  warn "or symlink it into ~/.local/bin."
fi

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) warn "$BIN_DIR is not on your PATH; use the full path or add it to your shell profile." ;;
esac

cat <<EOF

$(printf '\033[1;32mDone.\033[0m')

Next steps:
  1. Restart OpenCode (or run /reload in an open TUI).
  2. Open a session. The prompt footer should show:  ● voice
  3. Hold Right Alt, speak, release. The footer shows REC, then transcribing.

Useful commands:
  /voice                  status / help
  /voice on|off|restart   control the hidden helper
  Ctrl+Alt+V              toggle the helper
  $BIN_DIR/opencode-voice-helper status
  $BIN_DIR/opencode-voice-helper attach

All audio and transcription stay on this machine. The local bridge listens
only on 127.0.0.1:4096.

If your shell cannot find 'ocvoice', add $BIN_DIR to PATH, for example:
  export PATH="$BIN_DIR:\$PATH"

If the footer does not appear:
  - run /reload, then /voice on
  - check: $BIN_DIR/opencode-voice-helper status
  - if you just joined the input group, log out and back in first
EOF
