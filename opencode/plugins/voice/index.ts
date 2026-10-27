import { Plugin } from "@opencode/plugin"

// The TUI part provides the /voice command and status indicator.  This server
// part only exists so OpenCode discovers the local plugin directory.
export default Plugin.define({
  id: "local.voice",
  setup() {},
})
