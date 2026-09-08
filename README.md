<div align="center">

# ⚡ Agent Harness

**Hotkey a chat bar. Type the task. Press Enter.**

A terminal pops out — Pi or Hermes already running, your prompt already submitted.

<br>

[![Noctalia](https://img.shields.io/badge/Noctalia-v5-8b5cf6?style=flat-square)](https://noctalia.dev)
[![plugin_api](https://img.shields.io/badge/plugin__api-24-22c55e?style=flat-square)](#)
[![Hyprland](https://img.shields.io/badge/Hyprland-0.55%2B-58e1ff?style=flat-square)](https://hypr.land)
[![tests](https://img.shields.io/badge/tests-25%20passing-22c55e?style=flat-square)](#verification)
[![license](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](LICENSE)

<br>

```
   ⌨  SUPER + P
        │
        ▼
  ┌──────────────────────────────────────────────┐
  │  ✦  What should Pi do?                       │
  │  ▏  refactor my hyprland binds…              │
  │                                              │
  │  [ Pi ] [ Hermes ]    ~/work    model…       │
  │  ⏎ open terminal     ⌥⏎ answer here          │
  └──────────────────────────────────────────────┘
        │  Enter
        ▼
  ╭──────────────────────────────────────────────╮
  │  π   ~/work            deepseek • high       │
  │                                              │
  │  ›  refactor my hyprland binds…              │
  │  ●  reading config/binds.lua                 │
  ╰──────────────────────────────────────────────╯
```

</div>

---

## Why this exists

Every agent CLI is already excellent. What's missing is the **first five seconds**: getting from
"idea" to "agent working, in the right directory, with the right context" without opening a
terminal, `cd`-ing somewhere, and typing the prompt again.

Agent Harness is that missing doorway. One chord, one box, one Enter — and you're in.

## The flow

| | |
| --- | --- |
| **⌨ `SUPER+P`** | The composer opens, keyboard-focused, over whatever you were doing |
| **⏎ `Enter`** | Writes the prompt to a private file and pops out a floating terminal running the selected agent |
| **⌥⏎ `Alt+Enter`** | Runs the agent's print mode and renders the answer *inside the panel* — no window |
| **`Esc`** | Dismisses the panel (Noctalia owns this key; a plugin can't take it) |
| **🖱 click / scroll** | Toggle the composer / cycle the agent on that bar module |

Pick the agent with a chip, set the working directory, add a model, and optionally resume the
last session in that directory — then get out of the way.

## Install

```bash
noctalia msg plugins source add carlocamacho git https://github.com/CarloCamacho/noctalia-agent-harness
noctalia msg plugins enable carlocamacho/agent-harness
```

Then bind it in `~/.config/hypr/config/binds.lua`:

```lua
hl.bind(mainMod .. " + P",
  hl.dsp.exec_cmd("noctalia msg panel-toggle carlocamacho/agent-harness:compose"),
  { description = "Agent Harness composer" })
```

<details>
<summary>Requirements</summary>

| | |
| --- | --- |
| Noctalia v5 | `plugin_api >= 24` |
| Hyprland 0.55+ | Lua config (`hl.dsp.exec_cmd`, `hl.window_rule`) |
| A terminal | `kitty` (verified default), Ghostty, or Alacritty |
| An agent | `pi` and/or `hermes` on `PATH` |

</details>

## How it works

```
   panel ── composer                    service ── the rest
     │                                    │
     ├─ prompt   →  prompts/<token>.txt   ├─ resolve agents (PATH scan)
     ├─ script   →  launch/<token>.sh     ├─ apply the window rule
     └─ hyprctl dispatch                  ├─ detect running agents
          'hl.dsp.exec_cmd("sh …")'       └─ sweep generated files
                 │
                 ▼
   PATH=<agent runtime>:… ; cd <cwd> ; uwsm-app -- kitty --class agent-harness -e <agent> "$(cat <prompt>)"
```

**The prompt never enters a command string.** It goes to a `0600` file, and the command that
reaches the shell contains only generated paths and validated enums:

| Delivery | Shape | Used by |
| --- | --- | --- |
| `cat-file` | `… pi "$(cat '<file>')"` | Pi |
| `flag-file` | `… hermes chat --query-file '<file>'` | Hermes |

`$(cat …)` is command substitution producing one argument — the file's contents are *data*,
never parsed. Generated files are swept after 10 minutes, never immediately after launch (the
shell may not have read them yet).

## Verification

This plugin was built on a completed Phase 0 that ran against the real binaries and compositor.
The findings live in [`docs/phase0-findings.md`](docs/phase0-findings.md).

| Assumption | Result |
| --- | --- |
| `pi "<prompt>"` seeds an interactive session | ✅ confirmed in Pi's session JSONL |
| `hermes chat --query-file` is shell-free | ✅ byte-exact, upstream-tested |
| `hyprctl dispatch 'hl.dsp.exec_cmd(…)'` | ✅ works, and *is* shell-interpreted |
| Runtime floating window rule | ✅ 900×600 centered, on the active workspace |
| `capture_keys` grammar | ⚠️ Super rejected; **Escape is host-reserved** |
| The daemon's PATH has the agent runtime | ❌ it does not — resolved with a merged search path |

Live testing caught three bugs that source reading alone missed: `onEnable` isn't called on hot
reload, the daemon's PATH is bare, and the launch script has to wrap the agent *in* the terminal.
All three are fixed and pinned by regression tests.

```bash
python3 -m unittest discover -s tests    # 25 tests
luac5.4 -p plugin/agent-harness/*.luau   # syntax
```

## Settings

| Setting | Default | Notes |
| --- | --- | --- |
| Default agent | Pi | Which chip is preselected |
| Terminal | kitty | The pop-out terminal |
| Default working directory | `~/work` | Pi keeps a separate session per directory |
| Window class | `agent-harness` | Matches the generated window rule |
| Float the pop-out window | on | Centered, current workspace |
| Window width / height | 900 × 600 | |
| Trust project files | **off** | Passes `--approve` to Pi — enable only in directories you trust |

Per-widget: which agent that instance represents, and whether to show its name.

## Adding an agent

`lib/agents.luau` is a table. Declare `detect`, `delivery`, `capabilities`, `build(opts)`,
`oneShot(opts)`, and an optional `sessionDir`. The panel renders only the capabilities you
declare, and the validator rejects any adapter whose fixed argv contains shell metacharacters.

```lua
claude = {
  id = "claude", label = "Claude Code", glyph = "brain", detect = "claude",
  delivery = "cat-file", verified = false,
  capabilities = { model = true, continue = true },
  build = function(opts) return { "claude" } end,
}
```

## Roadmap

- [ ] Third adapter (DSH needs profile enumeration — `dsh --profile tui` doesn't exist yet)
- [ ] Session picker beyond "continue last in this cwd"
- [ ] Drop a file onto the panel to attach it with Pi's `@file`
- [ ] Stream agent output into the panel (Pi has `--mode rpc`; Hermes has an ACP adapter)

<div align="center">
<br>
<sub>MIT · built for <a href="https://noctalia.dev">Noctalia v5</a> on Hyprland</sub>
</div>
