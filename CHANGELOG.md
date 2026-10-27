# Changelog

## v1.1.0 — 2026-10-27

- Route each transcript to the OpenCode session that was active when recording
  started, even if you switch tabs or apps before releasing Right Alt.
- The TUI plugin publishes a short-lived target session; the bridge delivers
  through `opencode api` instead of raw keystrokes.
- Suppress the helper's follow-up Return after routed delivery, so it cannot
  submit whichever tab happens to be focused.
- Fall back to `wtype` only when no fresh target exists. If a target exists but
  delivery fails, report the error instead of typing into another chat.
- Check TUI focus before claiming a dictation, so a background OpenCode window
  cannot steal a recording started elsewhere.
- Add bridge tests for routed delivery, stale targets, safe failure, and the
  standalone fallback.
- Document target/active state files and routing overrides.

## v1.0.0 — 2026-10-27

- First public release.
- Hidden `tmux` voice helper with local whisper.cpp transcription.
- Localhost bridge that types transcripts into the OpenCode prompt and submits them.
- OpenCode TUI plugin: live footer state, mic meter, `/voice`, and `Ctrl+Alt+V`.
- **OpenCode (with voice)** launcher and desktop entries.
- Installer, uninstaller, optional systemd bridge service, and smoke tests.
