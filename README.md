# OpenCode voice input (local, offline)

[![checks](https://github.com/Rocketkid300/opencode-voice-kit/actions/workflows/checks.yml/badge.svg)](https://github.com/Rocketkid300/opencode-voice-kit/actions/workflows/checks.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![platform: Linux + Wayland](https://img.shields.io/badge/platform-Linux%20%2B%20Wayland-2ea44f.svg)](#requirements)

Push-to-talk dictation for the OpenCode TUI. Hold **Right Alt**, speak,
release. The transcript is delivered to the OpenCode chat that was active
when you started recording and submitted there. Switch tabs or apps while
speaking and it still lands in the right conversation. Everything runs
locally: whisper.cpp for speech recognition, a tiny localhost bridge, and
OpenCode's own local API. No API keys, no cloud.

The voice process runs in a hidden `tmux` session, so there is no extra
window. The TUI plugin starts it automatically and shows live state in the
prompt footer. Tested on Arch Linux + Hyprland with OpenCode 2.1.4.

```text
Hold Right Alt   ● voice REC 2.4s ▰▰▰▱▱
Release          ● voice ⠸ transcribing ▱▰▱▱▱
Done             ● voice → sending
Chat             refactor the parser and add tests   ⏎ submitted in that chat
```

| Footer | Meaning |
| --- | --- |
| `○ voice off` | Helper is stopped |
| `● voice` | Ready — hold Right Alt |
| `● voice REC 2.4s ▰▰▱▱▱` | Recording; the bar follows your mic level |
| `● voice ⠸ transcribing ▱▰▱▱▱` | Whisper is working |
| `● voice → sending` | Delivering to the chat where recording started |
| `● voice ! error` | Something failed; it recovers automatically |

## Requirements

- **Linux + Wayland** with virtual-keyboard support (`zwp_virtual_keyboard_v1`)
  for the `wtype` fallback. Routed dictation into an OpenCode chat uses
  OpenCode's local API instead. Hyprland and Sway work. KDE Plasma generally
  works. GNOME supports routed dictation but not the `wtype` fallback.
- **OpenCode v2** with the `opencode` CLI on `PATH` (the bridge uses
  `opencode api` to reach the target chat).
- `tmux`, `python3`, `curl`, `wtype`, and `jq` (only the optional launcher
  needs `jq`). `wtype` is used only when no OpenCode chat target exists.
- Rust toolchain (`cargo`), `clang`, `cmake`, `pkg-config`, and ALSA headers
  to build whisper.cpp.
- Your user in the **`input` group**, so the global hotkey can read
  `/dev/input/event*`. After adding the group, log out and back in.

Arch:

```bash
sudo pacman -S --needed base-devel clang cmake pkgconf alsa-lib \
  tmux python wtype jq
sudo usermod -aG input "$USER"   # then log out and back in
```

Debian/Ubuntu:

```bash
sudo apt install build-essential clang cmake pkg-config libasound2-dev \
  tmux python3 wtype jq
sudo usermod -aG input "$USER"   # then log out and back in
```

Fedora:

```bash
sudo dnf install gcc gcc-c++ clang cmake pkgconf-pkg-config \
  alsa-lib-devel tmux python3 wtype jq
sudo usermod -aG input "$USER"   # then log out and back in
```

Rust: <https://rustup.rs>.

## Install

From GitHub:

```bash
git clone https://github.com/Rocketkid300/opencode-voice-kit.git
cd opencode-voice-kit
./install.sh
```

From a zip:

```bash
unzip opencode-voice-kit.zip
cd opencode-voice-kit
./install.sh
```

If your shell cannot find `ocvoice` afterwards, add `~/.local/bin` to your
`PATH`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

The installer:

1. Checks prerequisites and warns if `input` group access is missing.
2. Builds `opencode-voice` 0.1.4 with
   `WHISPER_DONT_GENERATE_BINDINGS=1` (a plain build fails on newer
   clang/bindgen).
3. Downloads the `base.en` whisper model (~142 MB) on first install.
4. Copies the helper, bridge, wrapper, launcher, and TUI plugin.
5. Adds desktop entries.

Useful installer flags:

```bash
./install.sh --skip-voice     # binary already installed
./install.sh --skip-model     # model already downloaded
./install.sh --with-systemd   # also run the bridge as a user service
./install.sh --yes            # no download prompt
```

For a more accurate (but slower) model, install with:

```bash
OPENCODE_VOICE_MODEL=small.en ./install.sh
```

To switch later, restart the helper with:

```bash
OPENCODE_VOICE_MODEL=small.en ~/.local/bin/opencode-voice-helper restart
```

## Use

1. Restart OpenCode (or run `/reload` in an open TUI).
2. Open a session. The footer should show `● voice`.
3. Hold **Right Alt**, speak normally, release.
4. The footer turns red and shows the recording time and mic level. After
   release it shows `transcribing`, then the transcript is delivered to the
   chat where you started and submitted there.

In OpenCode:

```text
/voice                 status / help
/voice on              start the hidden helper
/voice off             stop it
/voice restart         restart it
/voice toggle          toggle it
Ctrl+Alt+V             toggle the helper
```

The helper runs in `tmux` session `opencode-voice`. To see its screen:

```bash
~/.local/bin/opencode-voice-helper attach
```

The **OpenCode (with voice)** desktop entry starts voice and focuses an
existing TUI (on Hyprland) or opens OpenCode in a terminal. The secondary
**Voice Input (dictation only)** entry attaches to the hidden voice session.

## Chat routing

The TUI plugin records the active session when recording starts. The bridge
delivers the transcript to that session through `opencode api`, so switching
tabs or apps while you speak cannot send it to the wrong chat.

- **Switch tabs while speaking** — the transcript still goes to the tab where
  you started holding Right Alt.
- **Switch to another app** — the transcript is delivered in the background;
  OpenCode does not need to stay focused.
- **Target session unavailable** — voice reports an error in the helper and
  does not fall back to typing, because that could submit another chat.
- **No fresh target** — standalone `ocvoice`, the OpenCode home screen, or a
  non-OpenCode app uses the original `wtype` fallback and types into the
  focused window.

The plugin writes a short-lived target in
`~/.local/state/opencode-voice/target.json` and a diagnostic heartbeat in
`active.json`. Both contain the session ID, title, and project directory —
never audio. The target expires automatically: it stays fresh while recording
and for 30 seconds after the recording ends (or two minutes if the plugin
stops refreshing it).

Overrides:

```bash
OPENCODE_VOICE_STATE_DIR=~/.local/state/opencode-voice
OPENCODE_VOICE_TARGET_FILE=~/.local/state/opencode-voice/target.json
OPENCODE_VOICE_TARGET_TTL=120   # seconds
```

## How it works

```text
Right Alt (evdev)
      │
      ▼
opencode-voice  ── whisper.cpp (local model)
      │
      │  POST /tui/append-prompt
      ▼
opencode-voice-typer  (127.0.0.1:4096)
      │
      ├─ fresh target? ──▶ opencode api ──▶ the chat where REC started
      │
      └─ no target ──────▶ wtype ──▶ focused window ── Enter
```

The TUI plugin writes the active session to `target.json` when it sees the
helper start recording. The bridge reads that file when the transcript
arrives and submits it to the exact session with
`opencode api POST /api/session/<id>/prompt`. It then acknowledges the
helper's follow-up submit request without pressing Return, so a different tab
cannot be submitted by accident.

OpenCode v2 removed the old prompt endpoints that `opencode-voice` 0.1.4
uses, so the bridge translates those calls into either the local API or
`wtype` keystrokes. The `wtype` path focuses an `OC |` window on Hyprland
before typing; on other compositors it types into the currently focused
window. Set `OPENCODE_VOICE_NO_FOCUS=1` to disable the focus attempt.

## Repository layout

```text
bin/opencode-voice-helper   start/stop/status the hidden tmux helper
bin/ocvoice                 run the voice UI and bridge
bin/opencode-voice-typer    localhost bridge (Python, stdlib only)
bin/opencode-with-voice     optional "OpenCode (with voice)" launcher
opencode/plugins/voice/     OpenCode TUI plugin (footer + /voice + keybind)
systemd/                    optional bridge user service
desktop/                    optional desktop entries
tests/                      installer and bridge smoke tests
install.sh / uninstall.sh   installation helpers
```

## Troubleshooting

**The footer does not show `voice`.**
- Run `/reload` in OpenCode, then `/voice on`.
- Check: `~/.local/bin/opencode-voice-helper status`.
- Make sure OpenCode was restarted after installation (plugins load at TUI
  startup).
- If you just added yourself to the `input` group, log out and back in.

**Holding Right Alt does nothing.**
- Check `~/.local/bin/opencode-voice-helper status`.
- Run `opencode-voice --debug` in a terminal to see key events and audio.
- Confirm your keyboard is a real evdev device and you are in `input`:
  `id -nG | tr ' ' '\n' | grep input`.
- Right Alt is `KEY_RIGHTALT`. On some layouts it is AltGr; the global
  listener sees it regardless, but another app may also react to it.

**“Recording too short”** means Right Alt was released too quickly. Hold it
for the whole phrase (at least half a second).

**Text is not delivered.**
- Check the bridge log: `tail -f ~/.local/state/opencode-voice-typer.log`.
- If the log says `target: ses_...` and then `delivery ... failed`, OpenCode
  could not reach that session. Check `opencode service status` and that the
  `opencode` CLI is on the bridge's `PATH`.
- If the log says `typing into`, the bridge used the fallback. On
  non-Hyprland compositors, keep OpenCode focused when you release.
- Confirm `wtype` works in your compositor for the fallback. Routed delivery
  does not use it.

**The transcript went to the wrong chat.**
- Run `/reload` so the current TUI plugin is loaded. Older plugins only type
  into the focused prompt.
- Check the target the bridge saw:
  `cat ~/.local/state/opencode-voice/target.json`.
- Check the active-tab heartbeat:
  `cat ~/.local/state/opencode-voice/active.json`.
- In the log, routed delivery looks like `target: ses_...` and
  `delivered to ses_...`; the fallback looks like `typing into: ...`.
- If two OpenCode TUIs are open, the one that was focused when recording
  started claims the dictation.

**The helper shows `delivery ... failed` but the right chat exists.**
- The bridge uses `opencode api`, which connects to OpenCode's background
  service. Run `opencode service status` and make sure the CLI is available
  outside your interactive shell.
- The session may have been deleted between recording and delivery.

**Port 4096 is already in use.**
- Start the wrapper with `OPENCODE_VOICE_PORT=4097 ocvoice` (and use the
  same port for the bridge/service).
- The bridge only listens on `127.0.0.1`.

**Transcription is slow.**
- `base.en` is the default. `small.en` is more accurate but slower.
- The first transcription after starting loads the model; later ones are
  faster.

**The footer is stuck on `starting`.**
- The helper is loading the whisper model. Wait a few seconds after login.
- Check the hidden session: `tmux capture-pane -p -t opencode-voice | tail`.

## Uninstall

```bash
./uninstall.sh           # remove scripts, plugin, and desktop entries
./uninstall.sh --purge   # also remove the binary, model, and logs
```

Or remove everything by hand:

```bash
~/.local/bin/opencode-voice-helper stop
systemctl --user disable --now opencode-voice-typer.service 2>/dev/null || true
rm -f ~/.config/systemd/user/opencode-voice-typer.service
rm -rf ~/.config/opencode/plugins/voice
rm -f ~/.local/bin/{opencode-voice-helper,opencode-voice-typer,ocvoice,opencode-with-voice}
rm -f ~/.local/share/applications/{opencode-voice.desktop,voice-input.desktop}
rm -rf ~/.local/state/opencode-voice   # optional, removes routing state
cargo uninstall opencode-voice            # optional
rm -rf ~/.local/share/opencode-voice      # optional, removes the model
```

## Privacy and security

- Audio is captured locally and transcribed by a local whisper model.
- The bridge listens only on `127.0.0.1:4096`.
- Routing state stays on disk under `~/.local/state/opencode-voice`; it
  contains session IDs, titles, and project directories, never audio.
- Nothing is uploaded. The only network access is the one-time model
  download from Hugging Face during installation.
- The bridge intentionally trusts local processes. Do not expose its port,
  and only run it on a machine you trust.

## Sharing

The repo is the whole kit. The installer builds the binary and downloads the
model on the friend's machine, so the repo stays small. Do not commit the
model file or a compiled `opencode-voice` binary.

If the friend uses Windows, macOS, or GNOME, this particular kit will not
work as-is:
- macOS has native hotkey support in the crate, but the bridge would need a
  different text-injection method.
- GNOME supports routed dictation but not `wtype`'s virtual keyboard
  protocol, so the standalone fallback is unavailable.
- Windows would need a different hotkey/injection layer.

## Credits

- [`opencode-voice`](https://crates.io/crates/opencode-voice) — local
  whisper.cpp push-to-talk for OpenCode (Apache-2.0).
- [OpenCode](https://opencode.ai) — TUI and plugin API.
- The helper, bridge, launcher, and TUI indicator in this kit are local
  integration code.
