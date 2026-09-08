# Noctalia Agent Harness — Pi-first Implementation Plan

> **Goal:** one hotkey opens a chat composer; type a request for Pi, press Enter, and the panel
> pops out into a terminal running Pi seeded with that prompt. Hermes is a second adapter behind
> the same flow — not a second plugin.

**Status:** **Phase 0 complete — see [`docs/phase0-findings.md`](docs/phase0-findings.md).**
Scaffold written and pushed. Every load-bearing assumption below was verified against the real
binaries and compositor; the corrections that came out of Phase 0 are marked **[P0]**.

**Headline Phase 0 results:** `pi "<prompt>"` does seed an interactive session (confirmed in
the session JSONL); `hermes --query-file` is byte-exact and shell-free; Hyprland 0.56.2
rejects the legacy `exec [float;size …]` syntax and needs the Lua dispatcher plus a runtime
window rule; **Escape is reserved by the host** and cannot be captured by a panel.

---

## Scope decision (v1)

**One plugin, two adapters, Pi first.**

The expensive parts — composer panel, service, bar module, terminal launch, prompt-file
lifecycle, session lookup — are identical for every agent. The per-agent part is an argv table
and a couple of resume flags. Two plugins would duplicate ~95% of the code, and Noctalia offers
no cross-plugin code sharing worth relying on (`require` is plugin-relative with entry-local
caches; `../` escapes the plugin directory but materialized plugins are separate exports, so
sibling coupling is fragile).

| In scope (v1) | Out of scope (v1) |
| --- | --- |
| Pi adapter, polished | User-editable agent registry |
| Hermes adapter behind the same seam | DSH / Claude Code / Codex adapters |
| Hotkey → composer → seeded TUI | Agent-availability picker with disabled entries |
| One-shot path (Alt+Enter) | Prompt history, snippets, voice |
| Per-cwd "continue last session" | Streaming agent output back into the panel |
| Prompt-file delivery, no shell exposure | Multi-agent fan-out |

**Why Pi first, even though Hermes is technically easier:** Hermes seeds natively via
`--query-file`, but Pi is the daily driver and the flow worth living in. Pi also needs the
harder case solved (`pi "<prompt>"` inline seeding), so getting Pi right exercises the design.

## Architecture

```
[[service]]  service.luau     adapter resolution, running state, prompt-file sweep, recents
[[widget]]   widget.luau      configurable bar module: agent glyph + running state
[[panel]]    panel.luau       hotkey-target composer; the only launcher
lib/         agents.luau      adapter table (Pi, Hermes) — the extension seam
             launch.luau      command composition, terminal resolution, temp files
             sessions.luau    per-cwd session discovery + "continue last"
             state.luau       state keys and schema versions
```

The service never launches anything; it owns detection, running state, and cleanup. The
**panel is the only launcher**, because it holds the user's intent (prompt + agent + cwd) at
the moment Enter is pressed.

## The prompt-delivery design (the part that matters)

The prompt is arbitrary text, and `runInTerminal`/`runAsync` string forms go through a shell.
v1 never puts prompt text in a command string. The prompt is written to a `0600` file in
`pluginDataDir()`, and the command contains **only a path this plugin generated**:

| Delivery | Composition | Used by |
| --- | --- | --- |
| `cat-file` | append `"$(cat '<promptFile>')"` as the final argv word | Pi |
| `flag-file` | append `--query-file '<promptFile>'` | Hermes (documented as never shell-interpreted) |

`$(cat …)` is command substitution producing a single argument — the file's contents are data
and are never parsed by the shell. The adapter supplies only fixed flags plus the file path, so
there is no user text to escape and no quoting surface to get wrong. This removes the
clipboard-fallback mode entirely.

**Temp-file lifetime:** the file must outlive the shell's `cat`, so it is **not** deleted
immediately after launch (that would race). It is swept on plugin enable and on each launch,
deleting files older than 10 minutes. Sweep is idempotent and unit-tested.

## Execution and terminal resolution

1. **[P0] Preferred:** `hyprctl dispatch 'hl.dsp.exec_cmd("sh <generated-script>")'` after
   applying a runtime rule with `hyprctl eval 'hl.window_rule({…})'`, so the terminal opens as a
   centered floating window on the current workspace — the "pop out to a CLI window" feel —
   rather than tiling into the layout. Exact rule syntax and focus behaviour are a Phase 0
   check.
2. **Fallback:** `noctalia.runInTerminal(cmd)` (host launcher), used when `hyprctl` is
   unavailable or the configured terminal cannot be resolved.
3. **Terminal preference:** configured order over the terminals present here — `kitty`,
   `ghostty`, `alacritty`.
4. Launch is fire-and-forget; the panel closes immediately and the widget picks up running
   state from the service.

## Stack

- Noctalia v5 Luau entries, `plugin_api = 24`; `ui.input` multiline + `submitOnEnter`
  (API 21) for the composer; `capture_keys`/`onKey` (API 13) for Escape and the one-shot chord;
  `processMatches` for running-state detection.
- Agents on this machine: `pi` (`~/.local/share/pi-node/…/bin`), `hermes` (`~/.local/bin`).
- Hyprland 0.56.2, terminals `kitty` / `ghostty` / `alacritty`.
- Registry/recents in `pluginDataDir()`; live state in `noctalia.state`.

## Scope corrections

- The plugin **launches** agents. It does not proxy their APIs, store credentials, or reimplement
  their TUI. Auth stays with each agent.
- The panel is a launcher and composer, not a chat client. Streaming agent output into the panel
  is deferred: it needs per-agent RPC/JSON modes and would duplicate each agent's own TUI.
- No auto-approval. Pi's `--approve` (trust project-local files) is **off by default** and
  exposed as an explicit toggle, because OS-configuration work touches files the agent may act
  on.
- Prompts are never written to Noctalia's log, state, or notifications.

## Proposed files

```
agent-harness/
  plugin/agent-harness/plugin.toml
  plugin/agent-harness/service.luau
  plugin/agent-harness/widget.luau
  plugin/agent-harness/panel.luau
  plugin/agent-harness/lib/agents.luau
  plugin/agent-harness/lib/launch.luau
  plugin/agent-harness/lib/sessions.luau
  plugin/agent-harness/lib/state.luau
  plugin/agent-harness/translations/en.json
  plugin/agent-harness/README.md
  plugin/agent-harness/CHANGELOG.md
  plugin/agent-harness/thumbnail.webp
  tests/test_launch.py      # command composition, hostile prompts, temp-file lifecycle
  tests/test_agents.py      # adapter contract, capability gating
  docs/ipc-contract.md
  docs/hyprland-bind.md
```

### Adapter contract (`lib/agents.luau`)

```lua
-- Every adapter is code, not user data. Adding an agent is one table.
return {
  pi = {
    id = "pi", label = "Pi", glyph = "terminal-2", detect = "pi", verified = true,
    delivery = "cat-file",                 -- [P0] "$(cat '<file>')" as the final argv word
    capabilities = { model = true, thinking = true, continue = true,
                     oneShot = true, approve = true, attach = true },
    build = function(o)                    -- o: promptFile, cwd, model, thinking, approve, files
      local a = { "pi" }
      if o.cwd then table.insert(a, "--") end
      if o.model then a = append(a, { "--model", o.model }) end
      if o.thinking then a = append(a, { "--thinking", o.thinking }) end
      if o.approve then table.insert(a, "--approve") end
      return a
    end,
    continueFlag = { "--continue" },
    oneShot = function(o) return { "pi", "--print" } end,
  },
  hermes = {
    id = "hermes", label = "Hermes", glyph = "sparkles", detect = "hermes", verified = true,
    delivery = "flag-file",                -- [P0] --query-file '<file>'
    capabilities = { model = true, provider = true, continue = true, oneShot = true },
    build = function(o)
      local a = { "hermes", "chat", "--query-file" }   -- path appended by launch.luau
      if o.model then a = append(a, { "-m", o.model }) end
      return a
    end,
    continueFlag = { "--continue" },
    oneShot = function(o) return { "hermes", "-z" } end, -- prints only the final answer
  },
}
```

`verified = false` means the argv has not been proven against the real CLI; the panel labels it
"unverified launcher" and Phase 0 flips it to true only after a recorded check.

### Manifest sketch

```toml
id = "carlocamacho/agent-harness"
name = "Agent Harness"
icon = "robot"
version = "0.1.0"
plugin_api = 24
author = "carlocamacho"
license = "MIT"
dependencies = []
tags = ["ai", "development", "productivity", "panel", "service"]

[[setting]]
key = "default_agent"
type = "select"
label_key = "settings.default_agent.label"
default = "pi"
# `options` is an array of { value, label_key } tables.
options = [
  { value = "pi",     label_key = "settings.default_agent.pi" },
  { value = "hermes", label_key = "settings.default_agent.hermes" },
]

[[setting]]
key = "terminal"
type = "select"
label_key = "settings.terminal.label"
default = "auto"
options = [
  { value = "auto",      label_key = "settings.terminal.auto" },
  { value = "kitty",     label_key = "settings.terminal.kitty" },
  { value = "ghostty",   label_key = "settings.terminal.ghostty" },
  { value = "alacritty", label_key = "settings.terminal.alacritty" },
]

[[setting]]
key = "default_cwd"
type = "folder"
label_key = "settings.default_cwd.label"
default = "~/work"

[[setting]]
key = "approve_project_files"
type = "bool"
label_key = "settings.approve_project_files.label"
description_key = "settings.approve_project_files.description"
default = false

[[setting]]
key = "float_window"
type = "bool"
label_key = "settings.float_window.label"
default = true

[[service]]
id = "service"
entry = "service.luau"

[[widget]]
id = "launcher"
entry = "widget.luau"
  [[widget.setting]]
  key = "agent"
  type = "select"
  label_key = "settings.widget.agent.label"
  default = "pi"
  options = [
    { value = "pi",     label_key = "settings.default_agent.pi" },
    { value = "hermes", label_key = "settings.default_agent.hermes" },
  ]
  [[widget.setting]]
  key = "show_label"
  type = "bool"
  label_key = "settings.widget.show_label.label"
  default = false

[[panel]]
id = "compose"
entry = "panel.luau"
width = 680
height = 360
placement = "floating"
position = "center"
keyboard_focus = "exclusive"
dismiss_on_outside_click = true
capture_keys = ["alt+Return"]   # [P0] Escape is host-reserved and must not be listed
```

## The hotkey flow (`docs/hyprland-bind.md`)

The primary entry point is a keybind, not the bar widget:

```conf
# ~/.config/hypr/bindings.conf
bind = SUPER, P, exec, noctalia msg panel-toggle carlocamacho/agent-harness:compose
```

Flow: keybind → panel opens with the composer focused → type the request → **Enter** → panel
closes → terminal opens on the current workspace with the agent seeded and the prompt in
context. **Escape** closes the panel. **Alt+Enter** runs the one-shot path and shows the answer
in the panel instead of opening a terminal.

## Phase 0 — feasibility gate (no real tasks, throwaway cwd)

1. **Verify Pi seeding.** In a scratch directory with a harmless marker prompt
   (`"reply with the single word OK"`), confirm that `pi "<prompt>"` opens an *interactive*
   session with the prompt as the first turn, rather than behaving one-shot. Record the exact
   invocation. This decides whether the Pi flow works as pictured at all.
2. **Verify Pi resume semantics.** Confirm `pi --continue` continues the previous session for
   the current project/cwd, and check the observed session layout
   (`~/.pi/agent/sessions/--<encoded-cwd>--/`). Confirm the cwd encoding so "continue last in
   this cwd" is real, not guessed.
3. **Verify the one-shot path.** `pi --print "<prompt>"` and `hermes -z "<prompt>"` — confirm
   both print only the answer and exit, with no TUI.
4. **Verify Hermes seeding.** `hermes chat --query-file <tmp>` seeds an interactive session on a
   real TTY (the help text says the prompt seeds the session); confirm before marking verified.
5. **Verify terminal launch.** Which `hyprctl dispatch exec` rule syntax actually produces a
   centered floating window, whether the new window receives focus, and whether
   `noctalia.runInTerminal` is configurable and focuses. Pick the default launch path from
   evidence, not preference.
6. **Verify `capture_keys` chord naming** for `Escape` and `alt+Return` (the chord arrives
   verbatim from the manifest).

**Exit criteria:** Pi and Hermes adapters are either `verified: true` with a recorded command,
or the panel labels them unverified. No unverified template ships silently.

## Phase 1 — adapter contract and launcher

1. `lib/agents.luau`: the adapter table above, with a validation pass that rejects an adapter
   whose fixed argv contains shell metacharacters and whose `delivery` is unknown.
2. `lib/launch.luau` — pure functions, no I/O:
   - `compose(adapter, opts) -> { argv, delivery, promptFile }`
   - `renderCommand(composed, terminal, floatRule) -> string` — shell-quotes every argv element
     **except** the deliberate `$(cat '<path>')` or the appended `--query-file '<path>'`.
   - `writePromptFile(dir, text) -> path` — `0600`, random name, no prompt in the filename.
   - `sweep(dir, maxAgeMs)` — idempotent orphan cleanup.
3. Capability gating: a field is only rendered when `capabilities` declares it, so the Pi/Hermes
   UI differs without branching inside the panel.

## Phase 2 — service (`service.luau`)

1. Resolve adapters on enable: `{ id, label, glyph, available, verified, capabilities }` via
   `commandExists`, published to `agent_status`.
2. Running-state detection with `noctalia.processMatches(onResult, needle…)` every 5–10 s,
   published as `{ id, running }` for the widget.
3. Maintain recents in `pluginDataDir()`: last used cwd, last model per agent, and the newest
   session per `(agent, cwd)` from the adapter's session dir. Never by executing the agent.
4. Sweep stale prompt files on `onEnable()` and before each launch.
5. IPC surface:

   | Event | Payload | Effect |
   | --- | --- | --- |
   | `refresh` | — | re-resolve adapters and running state |
   | `launch` | `{ agent, prompt, cwd, model, continue }` | launch without opening the panel |
   | `sweep` | — | delete stale prompt files |

## Phase 3 — widget (`widget.luau`)

1. Per-instance `agent` setting, so one bar can host Pi and another Hermes.
2. Glyph plus optional label; accent when that agent is running, dim when the binary is missing.
3. Tooltip: agent, binary path, resolved terminal, running state, last cwd.
4. Left click toggles the composer; `onScroll` cycles the adapter for that instance;
   `middle` remains the built-in settings action.

## Phase 4 — panel (`panel.luau`)

1. **Composer:** `ui.input({ multiline = true, submitOnEnter = true })` (API 21) — Enter
   submits, Shift+Enter inserts a newline. Keyboard focused on open.
2. **Agent chips:** a `ui.row` of `ui.button`s (Pi, Hermes), selected state shown; unavailable
   adapters disabled with a "not installed" tooltip. No `ui.select` — dropdowns are unavailable
   in persistent panels and chips read better here anyway.
3. **Context row:** cwd (default from settings, plus recents), model (free text seeded from the
   last used value), and an "approve project files" toggle that is **off by default** and only
   shown when the adapter declares the capability.
4. **Continue toggle:** "continue last session in this cwd" → adds the adapter's
   `continueFlag`; the resolved session is shown in the tooltip so the user knows what will
   resume.
5. **Enter:** `compose` → `writePromptFile` → `renderCommand` → `hyprctl dispatch exec` (or
   `runInTerminal`) → `panel.close()`.
6. **Alt+Enter:** run the adapter's one-shot argv through `runAsync`, render the output in the
   panel with `ui.markdown`, and keep the panel open. Useful for "what does this config key do"
   without opening a session.
7. **Failure paths** each produce a specific message, never a silent no-op: binary missing,
   unverified adapter, terminal not found, prompt file unwritable, `hyprctl` unavailable.

## Phase 5 — Hermes adapter

1. Add the adapter, flip `verified` only after Phase 0's `--query-file` check.
2. Confirm the panel degrades correctly: no `approve`/`thinking` controls, `provider` field
   appears instead.
3. Confirm `hermes --continue` resume semantics differ from Pi's and that the UI states which
   session will resume.

## Phase 6 — tests and delivery

1. Unit tests: hostile prompts (`"; rm -rf ~ #`, `$(id)`, backticks, newlines, NUL, 10k chars)
   must never appear unquoted in a composed command — under both deliveries the command contains
   only the generated path.
2. Temp-file tests: `0600` permissions, not deleted before the shell can read it, swept by age,
   filename free of prompt content.
3. Adapter tests: a malformed adapter disables only that entry; capability gating hides
   unsupported controls.
4. Manual matrix: Pi missing · Pi unverified · Hermes missing · terminal missing · `hyprctl`
   unavailable · cwd deleted between compose and launch · continue with no prior session ·
   prompt history off.
5. Confirm no prompt text reaches `noctalia.log`, state, or notifications.
6. Package per the workflow doc; local test via
   `~/.local/share/noctalia/plugins/agent_harness/` +
   `noctalia msg plugin carlocamacho/agent-harness:service all refresh`.
7. Submit to `noctalia-dev/community-plugins` (directory name `agent-harness` is free).

## Acceptance criteria

- `SUPER+P` opens the composer focused, on the current workspace, with no window focus stolen
  from the terminal the user is in.
- Typing a request and pressing Enter opens a terminal running Pi with that prompt as the first
  turn, and the panel closes.
- The same flow works for Hermes with no change to the hotkey; switching adapters is one chip
  click or one widget scroll.
- Alt+Enter returns an answer inside the panel without opening a terminal.
- "Continue last session in this cwd" resumes the session the user actually expects, and the
  panel names it before launching.
- A missing agent is shown unavailable and cannot be launched; an unverified launcher is
  labelled before use.
- No prompt text is ever interpolated into a shell string, and no prompt text reaches logs,
  state, or notifications.
- Disabling the plugin stops detection, leaves any running agent untouched, and sweeps its
  prompt files.

## Deferred scope

- A third adapter (DSH, Claude Code, Codex, OpenCode) — the seam exists, but DSH's `tui` profile
  does not exist on this machine and would need profile enumeration first.
- Streaming agent output into the panel (needs per-agent RPC/JSON modes).
- Session picker beyond "continue last in this cwd".
- Attaching files with Pi's `@file` via `ui.dropZone` (API 5) — a natural v1.1 feature.
- Prompt templates, snippets, voice input, multi-agent fan-out.

## Risks / rollback

| Risk | Mitigation |
| --- | --- |
| Pi does not seed an interactive session from argv | Phase 0 proves it before any UI is built; if it fails, the flow becomes "launch Pi in cwd, prompt on clipboard" and the plan is revisited |
| Prompt injection into the shell | prompt never enters the command string; only a generated path does; hostile-input tests |
| Prompt file deleted before the shell reads it | age-based sweep, never delete-on-launch; tested |
| `hyprctl` rule syntax or focus behaviour differs | Phase 0 verifies; `runInTerminal` fallback already designed |
| Agent flags drift between versions | adapters are code with a `verified` flag; failures are explicit, never guessed |
| Terminal opens on the wrong workspace | runtime `hl.window_rule` + `hl.dsp.exec_cmd` verified to open on the focused workspace during Phase 0 |

**Rollback:** disable the plugin. Detection stops, the widget disappears, prompt files are
swept, and no agent configuration or session is modified — the plugin only launches processes
the user explicitly asked for.

## Sources

- [Noctalia runtime API](https://docs.noctalia.dev/noctalia/plugins/development/runtime-api/) ·
  [Declarative UI](https://docs.noctalia.dev/noctalia/plugins/development/declarative-ui/) ·
  [Entry scripts](https://docs.noctalia.dev/noctalia/plugins/development/entries/) ·
  [Manifest & settings](https://docs.noctalia.dev/noctalia/plugins/development/manifest/) ·
  [Plugin API versions](https://docs.noctalia.dev/noctalia/plugins/development/plugin-api/)
- Local CLI evidence (captured during planning):
  - `pi --help` → `pi [options] [--] [@files...] [messages...]`, `--print/-p`,
    `--continue/-c`, `--resume/-r`, `--session`, `--model`, `--thinking`, `--approve/-a`,
    `--tui-mode`.
  - `hermes chat --help` → `-q/--query`, `--query-file PATH` ("nothing is shell-interpreted"),
    `--resume SESSION_ID`, `--continue [SESSION_NAME]`, `--tui`; `hermes -z` prints only the
    final response.
  - Session stores: `~/.pi/agent/sessions/--<encoded-cwd>--/`; `DSH_HOME=/home/ian/.dsh`.
  - Terminals present: `kitty`, `ghostty`, `alacritty`. Hyprland 0.56.2.
- Demand signal: Omarchy **Herdr** 28★ and **Hermes Harness** 25★, neither with a Noctalia
  equivalent in the 164-plugin community catalog (2026-09-08).
