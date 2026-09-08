# Phase 0 — Feasibility Findings

**Date:** 2026-09-08
**Environment:** CachyOS · Hyprland 0.56.2 (Lua config) · Noctalia v5 · kitty 0.42 ·
pi v0.85.1 · Hermes (hermes-agent checkout) · `$TERMINAL` unset

Every row was verified by running the real binary or reading its real source. Nothing here is
inferred from documentation alone unless the **Method** column says so.

---

## 1. Verified

| # | Question | Method | Result | Consequence |
| --- | --- | --- | --- | --- |
| 1 | Does `pi "<prompt>"` seed an interactive session? | PTY run + session JSONL | **Yes.** Session line 4 is a `user` message containing the marker text, line 5 the assistant reply | Pi is the primary adapter; `verified = true` |
| 2 | Does `pi -p` work one-shot? | Live run | **Yes.** `pi -p --no-session "…"` printed `OK`, exit 0 | Alt+Enter one-shot path is viable |
| 3 | Pi session layout | Live run | `~/.pi/agent/sessions/--<encoded-cwd>--/<ts>_<uuid>.jsonl`; cwd `/home/ian/work/agent-harness/scratch` → `--home-ian-work-agent-harness-scratch--` | Per-cwd "continue last session" is implementable |
| 4 | Does `hermes -z` work one-shot? | Live run | **Yes.** Printed `OK`, exit 0 | Hermes one-shot path is viable |
| 5 | Is `--query-file` safe for arbitrary text? | Source + upstream test | **Yes.** `_read_query_file()` reads the file into `args.query` byte-identically; upstream test asserts `$(touch …)` is preserved and not executed | Hermes `delivery = flag-file`; no quoting of user text |
| 6 | Does Hermes require a real TTY to seed? | Source (`main.py` TTY gate) | **Yes.** Interactive seeding is gated on `isatty()`; no-TTY bails out | Must launch inside a terminal — matches the design |
| 7 | What does `runInTerminal` do? | Noctalia source | Runs `<terminal> -e sh -lc "<cmd>"` detached; `$TERMINAL` wins if set, else discovery (Ghostty, Kitty, Alacritty, …) | Usable fallback; applies **no** window rules |
| 8 | How to launch a floating window on Hyprland 0.56.2? | Live run | `hyprctl dispatch 'hl.dsp.exec_cmd("<cmd>")'` works; legacy `exec [float;size …] cmd` is **rejected** (Lua config) | Launch mechanism corrected |
| 9 | Can a plugin apply a window rule at runtime? | Live run | **Yes.** `hyprctl eval 'hl.window_rule({ match = { class = "^agent-harness$" }, float = true, center = true, size = { "900", "600" } })'` then launching `kitty --class agent-harness` produced a floating, centered 900×600 window on the active workspace | No user config edit required |
| 10 | Is the exec_cmd string shell-interpreted? | Live run | **Yes.** `$(id -u)` expanded inside the string | `$(cat '<file>')` delivery is safe and works |
| 11 | Is the agent runtime on PATH? | Live run | Login shell (`sh -lc`) resolves `pi`, `hermes`, `dsh`, `kitty`; **Hyprland's exec_cmd PATH does not** include the pi node runtime | Compose commands with absolute paths / explicit PATH |
| 12 | `capture_keys` grammar | Noctalia source | `mod+…+key`; modifiers `ctrl\|control\|ctl`, `shift`, `alt\|option`. **Super/meta/logo/win/mod4 throws.** Key names case-insensitive; `enter`→`Return` | Use `alt+Return` for the one-shot chord |
| 13 | Can a panel capture Escape? | Noctalia source | **No.** `PluginPanel::handleGlobalKey` returns false for the configured Cancel action, so Escape always dismisses the panel | Do **not** list Escape in `capture_keys` |
| 14 | `uwsm-app` present? | Live check | **Yes**, `/usr/bin/uwsm-app` | Reuse the user's existing launch pattern |

## 2. Corrections to the plan

1. **Launch mechanism.** The plan assumed `hyprctl dispatch exec '[float;size …] cmd'`. On
   Hyprland 0.56.2 that syntax is rejected. The plugin now:
   - applies a runtime window rule via `hyprctl eval` for `class = "^agent-harness$"`, and
   - launches with `hyprctl dispatch 'hl.dsp.exec_cmd("sh <generated-script>")'`.
2. **`capture_keys`.** Escape is host-reserved, so the manifest declares only `alt+Return`.
3. **Prompt delivery.** `hl.dsp.exec_cmd` is shell-interpreted, so `$(cat '<file>')` (Pi) and
   `--query-file '<file>'` (Hermes) both work. The clipboard fallback is removed entirely.
4. **PATH.** The composed command must set an explicit `PATH` (the pi node bin directory at
   minimum), because the compositor's exec_cmd PATH omits it — this is exactly what the user's
   own `~/.local/bin/pi-agent-launch` works around.
5. **Generated launch script.** Rather than escaping the command into a Lua string for
   `hl.dsp.exec_cmd`, the plugin writes a per-launch shell script and passes only its path
   (a generated UUID name) to `exec_cmd`. This keeps the Lua string trivially safe and keeps all
   quoting in one testable place.

## 3. Prior art found on the machine

`~/.local/bin/pi-agent-launch` (bound to `SUPER+CTRL+P` in `config/binds.lua`) already does:

```bash
export PATH="$HOME/.local/share/pi-node/node-v22.23.2-linux-x64/bin:$HOME/.local/bin:$PATH"
exec uwsm-app -- kitty --class pi-agent --directory "$workdir" "$pi_bin"
```

The plugin should coexist with this, not replace it: same `uwsm-app -- kitty --class …` shape,
but with the prompt seeded and the class owned by the plugin so its window rule applies.

## 4. Residual unknowns (do not block the build)

| Unknown | Why it is acceptable |
| --- | --- |
| Pi `-c/--continue` cwd scoping | Docs say "continue most recent session"; sessions are stored per-cwd, so scoping is likely. The UI will show the resolved session before launching, and the user can fall back to `--resume` |
| Ghostty `--class` flag | `ghostty --help` did not list it; kitty is the configured default (`TERMINAL = "kitty"`) and the verified path |
| Hermes interactive seeding | Verified by source + upstream test + documented TTY gate, not by a live PTY run. Same delivery transport as one-shot, which is live-verified |
| Window rule persistence across Hyprland reload | Runtime rules are not persisted; the plugin re-applies on enable and before each launch |

## 5. Cleanup performed

Phase 0 created and then removed: scratch marker-prompt files, one Pi marker session
(`~/.pi/agent/sessions/--home-ian-work-agent-harness-scratch--/`), and two short-lived test
windows. No user session or configuration was modified.
