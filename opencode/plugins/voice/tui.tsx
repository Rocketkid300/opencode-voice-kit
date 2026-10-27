import { execFile } from "node:child_process"
import { existsSync } from "node:fs"
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

export default Plugin.define({
  id: "local.voice",
  async setup(context) {
    const [helperReady, setHelperReady] = createSignal(false)
    const [mode, setMode] = createSignal<VoiceMode>("off")
    const [elapsed, setElapsed] = createSignal(0)
    const [level, setLevel] = createSignal(0)
    const [tick, setTick] = createSignal(0)

    let stopped = false
    let pollTimer: ReturnType<typeof setTimeout> | undefined

    async function refreshHelper() {
      const result = await callHelper(["status"])
      if (stopped) return
      setHelperReady(result.ok)
      if (!result.ok) setMode("off")
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
      if (pane === null) {
        // Helper is running but not in the hidden tmux session (visible mode).
        setMode("ready")
      } else {
        const parsed = parsePane(pane)
        setMode(parsed.mode)
        setElapsed(parsed.elapsed)
        setLevel(parsed.level)
        active =
          parsed.mode === "recording" ||
          parsed.mode === "transcribing" ||
          parsed.mode === "sending"
        if (active) setTick((value) => value + 1)
      }

      // Poll quickly while the mic/whisper is active, slowly when idle.
      pollTimer = setTimeout(poll, active ? 120 : 400)
    }

    // Integrate voice with every OpenCode TUI.  The helper is a singleton, so
    // opening additional sessions does not start additional microphone users.
    // Do not block TUI startup while the helper loads its whisper model.
    const current = await callHelper(["status"])
    setHelperReady(current.ok)
    if (!current.ok) {
      void callHelper(["ensure"]).then(refreshHelper)
    }

    void poll()
    const helperTimer = setInterval(refreshHelper, 5_000)

    const unregisterStatus = context.ui.slot({
      append: "prompt.footer.status",
      render: () => {
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
    }
  },
})
