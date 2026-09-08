# Changelog

## 0.1.0 — unreleased

Initial scaffold, built on a completed Phase 0 feasibility pass
(see `docs/phase0-findings.md`).

- Pi and Hermes adapters, both verified against the real CLIs.
- Composer panel with agent chips, working directory, model/provider, continue-session and
  trust-project-files controls.
- Prompt delivery via a private file: `"$(cat '<file>')"` (Pi) or `--query-file '<file>'`
  (Hermes). No prompt text ever enters a command string.
- Floating pop-out terminal via `hyprctl eval 'hl.window_rule(…)'` plus
  `hyprctl dispatch 'hl.dsp.exec_cmd(…)'` (Hyprland 0.55+ Lua config).
- One-shot path on `Alt+Enter` (`pi --print`, `hermes -z`) rendering the answer in the panel.
- Configurable bar module, one instance per agent, scroll to switch.
- Age-based sweep of generated prompt and launch files.
