# noctalia-agent-harness

**Hotkey a chat bar, type a request, press Enter — and a terminal pops out running Pi (or
Hermes) with your prompt already submitted.**

A [Noctalia v5](https://noctalia.dev) plugin. This repository is the upstream source of truth;
the plugin id is `carlocamacho/agent-harness`.

```
SUPER+P  →  composer opens, focused  →  type  →  Enter  →  floating kitty running Pi
                                                       Alt+Enter  →  answer in the panel
```

---

## Status

**v0.1.0 scaffold, built on a completed Phase 0.** Every load-bearing assumption was verified
against the real binaries and compositor on CachyOS / Hyprland 0.56.2 — see
[`docs/phase0-findings.md`](docs/phase0-findings.md). Highlights:

| Verified | Result |
| --- | --- |
| `pi "<prompt>"` seeds an interactive session | **Yes** — the prompt lands as the first user message in the session JSONL |
| `pi -p` / `hermes -z` one-shot | **Yes** — both print the answer and exit 0 |
| `hermes chat --query-file <file>` | **Yes** — byte-identical, never shell-interpreted |
| `hyprctl dispatch 'hl.dsp.exec_cmd("…")'` | **Yes** — and the string *is* shell-interpreted |
| Runtime floating window rule | **Yes** — `hyprctl eval 'hl.window_rule(…)'` produced a centered 900×600 floating window |
| `capture_keys` grammar | Super is rejected; **Escape is host-reserved** and cannot be captured |
| `runInTerminal` | Wraps as `<terminal> -e sh -lc "<cmd>"`, applies no window rules |

## How it works

```
panel (composer)                     service
  │                                    │
  ├─ write prompt  → prompts/<id>.txt  ├─ resolve adapters (PATH scan)
  ├─ write script  → launch/<id>.sh    ├─ apply Hyprland window rule
  └─ hyprctl dispatch                  ├─ detect running agents
       'hl.dsp.exec_cmd("sh <script>")' └─ sweep generated files
                 │
                 ▼
   script:  PATH=<agent runtime>:… ; cd <cwd> ; exec <agent> "$(cat <prompt>)"
```

**The prompt never enters a command string.** It is written to a `0600` file, and the command
reaching the shell contains only generated paths and validated enums:

- Pi (`cat-file`): `exec pi … "$(cat '<promptFile>')"` — command substitution, so the text is
  data, never parsed.
- Hermes (`flag-file`): `exec hermes chat --query-file '<promptFile>'` — documented as
  shell-free transport.

Generated files are swept by age (10 minutes) on plugin enable and before each launch. They are
**never** deleted immediately after launch, because the shell may not have read them yet.

## Install

```bash
noctalia msg plugins source add carlocamacho git https://github.com/CarloCamacho/noctalia-agent-harness
noctalia msg plugins enable carlocamacho/agent-harness
```

Or drop the plugin directory under `~/.local/share/noctalia/plugins/agent_harness/` and enable it
from **Settings → Plugins**.

Then bind the composer (see [`docs/hyprland-bind.md`](docs/hyprland-bind.md)):

```lua
-- ~/.config/hypr/config/binds.lua  (Hyprland 0.55+ Lua config)
hl.bind(mainMod .. " + P", hl.dsp.exec_cmd("noctalia msg panel-toggle carlocamacho/agent-harness:compose"),
        { description = "Agent Harness composer" })
```

## Usage

| Action | Result |
| --- | --- |
| Hotkey | Opens the composer, keyboard-focused |
| Enter | Opens a floating terminal running the selected agent with the prompt submitted |
| Alt+Enter | Runs the agent's print mode and renders the answer inside the panel |
| Escape | Dismisses the panel (handled by Noctalia — a plugin cannot capture it) |
| Click the bar module | Toggles the composer |
| Scroll the bar module | Cycles the agent for that instance |

## Settings

Plugin-level: default agent, terminal, default working directory, window class, float toggle,
float size, and **Trust project files** (off by default — it passes `--approve` to Pi, which lets
it act on project-local instructions without asking; only enable it in directories you trust).

Per-widget: which agent that instance represents, and whether to show its name.

## Layout

```
plugin/agent_harness/
  plugin.toml            manifest (plugin_api 24; capture_keys = ["alt+Return"])
  service.luau           adapter resolution, window rule, running state, cleanup
  widget.luau            configurable bar module
  panel.luau             the composer and the only launcher
  lib/agents.luau        adapter table — the extension seam (Pi, Hermes)
  lib/launch.luau        quoting, script generation, hyprctl argv, sweep
  lib/sessions.luau      per-cwd session discovery
  lib/state.luau         state keys and schema version
  translations/en.json
docs/                    Phase 0 findings, IPC contract, keybind guide
tests/                   Python mirrors of the composition rules
```

## Adding an agent

`lib/agents.luau` is a table. An adapter declares `detect`, `delivery`
(`cat-file` / `flag-file`), `capabilities`, `build(opts)`, `oneShot(opts)`, and an optional
`sessionDir`. Nothing else changes: the panel renders only the capabilities an adapter declares,
and `lib/agents.luau` rejects any adapter whose fixed argv contains shell metacharacters.

## Roadmap

- Third adapter (DSH needs profile enumeration first — `dsh --profile tui` does not exist here).
- Session picker beyond "continue last in this cwd".
- Attach files to Pi with `@file` via a panel drop zone.
- Streaming agent output into the panel (Pi exposes `--mode rpc`; Hermes exposes an ACP adapter).

## License

MIT — see [`LICENSE`](LICENSE).
