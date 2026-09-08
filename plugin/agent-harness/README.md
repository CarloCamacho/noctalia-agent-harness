# Agent Harness

Open a chat composer from a hotkey; pressing Enter pops out a floating terminal running an
agent with your prompt already submitted.

Shipped adapters: **Pi** (`pi`) and **Hermes** (`hermes`). Both are verified against the real
CLIs — see the repository's `docs/phase0-findings.md`.

## Requirements

| Requirement | Why |
| --- | --- |
| Noctalia v5 with `plugin_api >= 24` | argv-form `runAsync` and `ui.input` `submitOnEnter` |
| Hyprland 0.55+ (Lua config) | `hl.dsp.exec_cmd` / `hl.window_rule` launch path |
| `kitty` (default), or Ghostty / Alacritty | the pop-out terminal |
| `pi` and/or `hermes` on `PATH` | the agents themselves |

## Bind it

```lua
hl.bind(mainMod .. " + P",
  hl.dsp.exec_cmd("noctalia msg panel-toggle carlocamacho/agent-harness:compose"),
  { description = "Agent Harness composer" })
```

## Behaviour

- **Enter** writes your prompt to a private file, generates a launch script, and opens the
  terminal via `hyprctl dispatch 'hl.dsp.exec_cmd("sh <script>")'`.
- **Alt+Enter** runs the agent's print mode and shows the answer in the panel.
- **Escape** closes the panel (reserved by Noctalia; not capturable by a plugin).
- A runtime window rule for the configured class makes the terminal float, centered, at the
  configured size on the current workspace. It is re-applied on enable, config change, and
  output change, since runtime rules do not survive a Hyprland reload.

## Prompt safety

The prompt is never interpolated into a command string. It is written to a `0600` file in the
plugin data directory and referenced either as `"$(cat '<file>')"` (Pi) or
`--query-file '<file>'` (Hermes). Generated files are swept after 10 minutes, never immediately
after launch.

## Settings

| Setting | Default | Notes |
| --- | --- | --- |
| Default agent | Pi | Which chip is preselected |
| Terminal | kitty | Pop-out terminal |
| Default working directory | `~/work` | Pi keeps a separate session per directory |
| Window class | `agent-harness` | Must match the generated window rule |
| Float the pop-out window | on | Centered, on the current workspace |
| Window width / height | 900 × 600 | |
| Trust project files | **off** | Passes `--approve` to Pi; enable only in trusted directories |

## IPC

```bash
# Launch without opening the composer (keybinds, scripts)
noctalia msg plugin carlocamacho/agent-harness:service all launch \
  '{"agent":"pi","prompt":"check my hyprland config","cwd":"~/work"}'

# Re-resolve agents and running state
noctalia msg plugin carlocamacho/agent-harness:service all refresh

# Delete stale generated files
noctalia msg plugin carlocamacho/agent-harness:service all sweep
```

## Limitations

- Hermes has no per-directory session store, so "continue last session" relies on Hermes's own
  `--continue` rather than a resolved session id.
- Ghostty's `--class` flag was not listed in its help output; kitty is the verified default.
- One-shot output is rendered as markdown; very long answers are scrolled, not paginated.
