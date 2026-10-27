import { execFile } from "node:child_process"
import { existsSync, mkdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from "node:fs"
import { homedir } from "node:os"
import { dirname, join } from "node:path"
import { createSignal, Show } from "solid-js"
import { Plugin } from "@opencode/plugin/tui"

const HELPER =
  [
    process.env.OPENCODE_VOICE_HELPER,
    `${process.env.HOME}/.local/bin/opencode-voice-helper`,
    `${process.env.HOME}/bin/opencode-voice-helper`,
  ].find((path): path is string => {
    if (!path) return false
    try {
      return existsSync(path)
    } catch {
      return false
    }
  }) || `${process.env.HOME}/.local/bin/opencode-voice-helper`

const SESSION = process.env.OPENCODE_VOICE_SESSION || "opencode-voice"

const STATE_HOME =
  process.env.XDG_STATE_HOME || join(process.env.HOME || homedir(), ".local/state")
const STATE_DIR = process.env.OPENCODE_VOICE_STATE_DIR || join(STATE_HOME, "opencode-voice")
const TARGET_FILE = process.env.OPENCODE_VOICE_TARGET_FILE || join(STATE_DIR, "target.json")
const ACTIVE_FILE = process.env.OPENCODE_VOICE_ACTIVE_FILE || join(STATE_DIR, "active.json")
const TARGET_TTL = (() => {
  const value = Number(process.env.OPENCODE_VOICE_TARGET_TTL || 120)
  return Number.isFinite(value) && value > 0 ? value * 1000 : 120_000
})()

type HelperResult = {
  ok: boolean
  output: string
}

type VoiceMode =
  | "off"
  | "starting"
  | "ready"
  | "recording"
  | "transcribing"
  | "sending"
  | "error"

type PaneState = {
  mode: VoiceMode
  elapsed: number
  level: number
}

type SessionTarget = {
  sessionID: string
  title?: string
  directory?: string
  startedAt: number
}

type StateRecord = {
  version: 1
  sessionID: string | null
  title?: string
  directory?: string
  mode: VoiceMode
  focused: boolean | null
  pid: number
  startedAt?: number
  updatedAt: number
  expiresAt: number
}

const SPINNER = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

function callHelper(args: string[]): Promise<HelperResult> {
  return new Promise((resolve) => {
    execFile(
      HELPER,
      args,
      {
        timeout: 20_000,
        env: process.env,
      },
      (error, stdout, stderr) => {
        resolve({
          ok: !error,
          output: (stdout || "").trim() || (stderr || "").trim(),
        })
      },
    )
  })
}

function capturePane(): Promise<string | null> {
  return new Promise((resolve) => {
    execFile(
      "tmux",
      ["capture-pane", "-p", "-t", SESSION],
      { timeout: 1_000, maxBuffer: 128 * 1024, env: process.env },
      (error, stdout) => resolve(error ? null : stdout),
    )
  })
}

function parsePane(text: string): PaneState {
  const lines = text.split("\n")
  // Search bottom-up: the live status line is the lowest state marker.
  for (let i = lines.length - 1; i >= 0; i--) {
    const line = lines[i]

    if (line.includes("Transcribing")) {
      return { mode: "transcribing", elapsed: 0, level: 0 }
    }
    if (line.includes("Sending to OpenCode")) {
      return { mode: "sending", elapsed: 0, level: 0 }
    }
    if (line.includes("✗ Error")) {
      return { mode: "error", elapsed: 0, level: 0 }
    }
    if (line.includes("REC [")) {
      const match = line.match(/REC\s*\[([|\s]*)\]\s*([\d.]+)s/)
      if (match) {
        return {
          mode: "recording",
          elapsed: Number.parseFloat(match[2]) || 0,
          level: (match[1].match(/\|/g) || []).length,
        }
      }
      return { mode: "recording", elapsed: 0, level: 0 }
    }
    if (line.includes("● Ready")) {
      return { mode: "ready", elapsed: 0, level: 0 }
    }
  }
  return { mode: "starting", elapsed: 0, level: 0 }
}

function meter(level: number, width = 5): string {
  const filled = Math.max(0, Math.min(width, Math.round((level / 8) * width)))
  return "▰".repeat(filled) + "▱".repeat(width - filled)
}

function sweep(frame: number, width = 5): string {
  const cycle = Math.max(1, width * 2 - 2)
  const position = frame % cycle
  const index = position < width ? position : cycle - position
  return Array.from({ length: width }, (_, i) => (i === index ? "▰" : "▱")).join("")
}

function isActiveMode(mode: VoiceMode): boolean {
  return mode === "recording" || mode === "transcribing" || mode === "sending"
}

function writeState(file: string, record: StateRecord) {
  try {
    mkdirSync(dirname(file), { recursive: true, mode: 0o700 })
    const temporary = `${file}.${process.pid}.tmp`
    writeFileSync(temporary, `${JSON.stringify(record)}\n`, {
      encoding: "utf8",
      mode: 0o600,
    })
    renameSync(temporary, file)
  } catch {
    // Dictation must keep working even when the state directory is read-only.
  }
}

function clearState(file: string) {
  try {
    unlinkSync(file)
  } catch {
    // Already gone.
  }
}

export default Plugin.define({
  id: "local.voice",
  async setup(context) {
    const [helperReady, setHelperReady] = createSignal(false)
    const [mode, setMode] = createSignal<VoiceMode>("off")
    const [elapsed, setElapsed] = createSignal(0)
    const [level, setLevel] = createSignal(0)
    const [tick, setTick] = createSignal(0)
    const [focused, setFocused] = createSignal<boolean | null>(null)

    let stopped = false
    let pollTimer: ReturnType<typeof setTimeout> | undefined
    let footerSessionID: string | undefined
    let lastFocusAt = 0
    let lastActiveKey = ""
    let lastActiveWrite = 0
    let lockedTarget: SessionTarget | undefined
    let wasActive = false

    function onFocus() {
      lastFocusAt = Date.now()
      setFocused(true)
    }

    function onBlur() {
      setFocused(false)
    }

    try {
      context.renderer.on("focus", onFocus)
      context.renderer.on("blur", onBlur)
    } catch {
      // Older hosts without renderer focus events still route by active tab.
    }

    function currentSessionID(): string | undefined {
      try {
        const route = context.ui.router.current()
        if (route.type === "session" && route.sessionID && route.sessionID !== "dummy") {
          return route.sessionID
        }
      } catch {
        // Fall through to the tab/footer sources.
      }
      try {
        const active = context.ui.tabs.list().find((tab) => tab.active)
        if (active?.sessionID) return active.sessionID
      } catch {
        // Tabs may be unavailable.
      }
      return footerSessionID
    }

    function sessionDetails(sessionID: string): { title?: string; directory?: string } {
      try {
        const session = context.data.session.get(sessionID)
        return {
          title: session?.title,
          directory: session?.location?.directory,
        }
      } catch {
        return {}
      }
    }

    function canRoute(): boolean {
      // Unknown focus (the terminal did not report it yet) is allowed.  Once
      // the TUI is known to be blurred, only a recent focus may claim a
      // dictation; this keeps a background TUI from stealing another one.
      return focused() !== false || Date.now() - lastFocusAt < 3_000
    }

    function clearTargetIfOwned() {
      try {
        const data = JSON.parse(readFileSync(TARGET_FILE, "utf8")) as { pid?: number }
        if (data?.pid === process.pid) clearState(TARGET_FILE)
      } catch {
        // No target, or another TUI owns it.
      }
    }

    function writeActive(currentMode: VoiceMode) {
      const sessionID = currentSessionID()
      const bucket = isActiveMode(currentMode) ? "active" : currentMode
      const key = `${sessionID || ""}|${bucket}|${String(focused())}`
      const now = Date.now()
      if (key === lastActiveKey && now - lastActiveWrite < 10_000) return
      lastActiveKey = key
      lastActiveWrite = now
      const details = sessionID ? sessionDetails(sessionID) : {}
      writeState(ACTIVE_FILE, {
        version: 1,
        sessionID: sessionID ?? null,
        title: details.title,
        directory: details.directory,
        mode: currentMode,
        focused: focused(),
        pid: process.pid,
        updatedAt: now,
        expiresAt: now + 30_000,
      })
    }

    function writeTarget(currentMode: VoiceMode, target: SessionTarget, active: boolean) {
      const now = Date.now()
      writeState(TARGET_FILE, {
        version: 1,
        sessionID: target.sessionID,
        title: target.title,
        directory: target.directory,
        mode: currentMode,
        focused: focused(),
        pid: process.pid,
        startedAt: target.startedAt,
        updatedAt: now,
        expiresAt: now + (active ? TARGET_TTL : 30_000),
      })
    }

    function lockTarget(currentMode: VoiceMode) {
      lockedTarget = undefined
      if (!canRoute()) {
        // This TUI is blurred.  Invalidate a target left by an earlier
        // dictation here, but leave another TUI's target alone.
        clearTargetIfOwned()
        return
      }

      const sessionID = currentSessionID()
      if (!sessionID) {
        // The user is on the home screen.  A stale target must not capture a
        // dictation that has no OpenCode destination.
        clearState(TARGET_FILE)
        return
      }

      const details = sessionDetails(sessionID)
      lockedTarget = {
        sessionID,
        title: details.title,
        directory: details.directory,
        startedAt: Date.now(),
      }
      writeTarget(currentMode, lockedTarget, true)
    }

    async function refreshHelper() {
      const result = await callHelper(["status"])
      if (stopped) return
      setHelperReady(result.ok)
      if (!result.ok) {
        setMode("off")
        clearTargetIfOwned()
        writeActive("off")
      }
    }

    async function poll() {
      if (stopped) return

      if (!helperReady()) {
        pollTimer = setTimeout(poll, 500)
        return
      }

      const pane = await capturePane()
      if (stopped) return

      let active = false
      let currentMode: VoiceMode = "ready"
      if (pane === null) {
        // Helper is running but not in the hidden tmux session (visible mode).
        setMode("ready")
      } else {
        const parsed = parsePane(pane)
        currentMode = parsed.mode
        setMode(parsed.mode)
        setElapsed(parsed.elapsed)
        setLevel(parsed.level)
        active = isActiveMode(parsed.mode)
        if (active) setTick((value) => value + 1)
      }

      writeActive(currentMode)

      if (active) {
        if (!wasActive) lockTarget(currentMode)
        else if (lockedTarget) writeTarget(currentMode, lockedTarget, true)
      } else if (wasActive && lockedTarget) {
        // Keep a short grace period for the bridge's submit call, but do not
        // keep an old target fresh for later, unrelated dictation.
        writeTarget(currentMode, lockedTarget, false)
      }
      wasActive = active

      // Poll quickly while the mic/whisper is active, often enough when idle
      // to catch the start of a short recording.
      pollTimer = setTimeout(poll, active ? 120 : 250)
    }

    // Integrate voice with every OpenCode TUI.  The helper is a singleton, so
    // opening additional sessions does not start additional microphone users.
    // Do not block TUI startup while the helper loads its whisper model.
    const current = await callHelper(["status"])
    setHelperReady(current.ok)
    writeActive(current.ok ? "ready" : "off")
    if (!current.ok) {
      void callHelper(["ensure"]).then(refreshHelper)
    }

    void poll()
    const helperTimer = setInterval(refreshHelper, 5_000)

    const unregisterStatus = context.ui.slot({
      append: "prompt.footer.status",
      render: (input) => {
        footerSessionID = input.sessionID
        const color = () => {
          switch (mode()) {
            case "recording":
            case "error":
              return context.theme.text.feedback.error.base
            case "transcribing":
              return context.theme.text.feedback.warning.base
            case "sending":
              return context.theme.hue.accent[500]
            case "off":
            case "starting":
              return context.theme.text.muted
            default:
              return context.theme.text.feedback.success.base
          }
        }

        const label = () => {
          switch (mode()) {
            case "off":
              return "○ voice off"
            case "starting":
              return "○ voice starting"
            case "recording":
              return `● voice REC ${elapsed().toFixed(1)}s ${meter(level())}`
            case "transcribing":
              return `● voice ${SPINNER[tick() % SPINNER.length]} transcribing ${sweep(tick())}`
            case "sending":
              return "● voice → sending"
            case "error":
              return "● voice ! error"
            default:
              return "● voice"
          }
        }

        return (
          <Show when={helperReady()} fallback={<text fg={context.theme.text.muted}>○ voice off</text>}>
            <text fg={color()}>{label()}</text>
          </Show>
        )
      },
    })

    context.keymap.layer(() => ({
      mode: "global",
      priority: 10,
      commands: [
        {
          id: "voice.command",
          title: "Voice: dictation help",
          description: "Hold Right Alt to dictate into the prompt",
          group: "Voice",
          palette: true,
          slash: { name: "voice", arguments: true },
          run: async (input) => {
            const argument = (input || "").trim().toLowerCase()

            if (!argument || argument === "status") {
              const result = await callHelper(["status"])
              context.ui.toast.show({
                title: "Voice",
                message: result.ok
                  ? `${result.output} — hold Right Alt to dictate`
                  : "Voice is off — use /voice on to start it",
                variant: result.ok ? "success" : "warning",
              })
              return
            }

            if (!["on", "off", "toggle", "restart"].includes(argument)) {
              context.ui.toast.show({
                title: "Voice",
                message: "Usage: /voice [on|off|toggle|restart|status] — or just hold Right Alt",
                variant: "info",
              })
              return
            }

            const command = argument === "on" ? "start" : argument
            const result = await callHelper([command])
            await refreshHelper()
            context.ui.toast.show({
              title: "Voice",
              message: result.output || (result.ok ? "Done" : "Voice command failed"),
              variant: result.ok ? "success" : "error",
            })
          },
        },
        {
          id: "voice.toggle",
          title: "Voice: toggle local dictation",
          description: "Start or stop the hidden local dictation helper",
          group: "Voice",
          bind: "ctrl+alt+v",
          palette: true,
          run: async () => {
            const result = await callHelper(["toggle"])
            await refreshHelper()
            context.ui.toast.show({
              title: "Voice",
              message: result.output || (result.ok ? "Done" : "Voice command failed"),
              variant: result.ok ? "success" : "error",
            })
          },
        },
      ],
      bindings: ["voice.toggle"],
    }))

    return () => {
      stopped = true
      if (pollTimer) clearTimeout(pollTimer)
      clearInterval(helperTimer)
      unregisterStatus()
      try {
        context.renderer.off("focus", onFocus)
        context.renderer.off("blur", onBlur)
      } catch {
        // Nothing to detach.
      }
    }
  },
})
