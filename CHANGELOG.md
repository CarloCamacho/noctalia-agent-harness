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
- Live end-to-end verified: hotkey → composer → floating kitty → Pi seeded → answer.

### Fixed after live testing

- Service now initialises at script load as well as in `onEnable()` — hot reload does not call
  `onEnable()`, which left the adapter table empty and rejected every launch.
- Agent resolution now searches known per-user directories, then a probed login-shell PATH,
  then the daemon PATH. The Noctalia daemon runs with a bare system PATH, and its `sh -lc`
  does not source fish config, so the probe must augment rather than replace the list.
- The generated launch script now wraps the agent in the configured terminal
  (`uwsm-app -- kitty --class … -e …`) for interactive launches, and skips the terminal only
  for one-shot runs. Exec'ing the agent bare produced no window.
- Regression tests for all three (25 tests total).
- The panel did not forward the prompt-file path into `launchOptions()`, so pressing Enter or
  Alt+Enter in the composer failed with *"Missing prompt file"*. Both call sites now pass it, and
  the wiring is pinned by `tests/test_panel.py` (29 tests total). Verified live: Enter opened a
  floating terminal with the prompt submitted, and Alt+Enter returned the answer with no window.
- One-shot answers were unreadable: the panel was 360px tall, so after the composer rows the
  output scroll had roughly 30px, and `stickToBottom` pinned the view to the *end* of the answer.
  The panel is now 560px, and once a run starts the composer collapses into a result view whose
  scroll region takes the remaining height and starts at the top. A live elapsed counter replaces
  the static "running…" label. `tests/lua/` adds a stubbed-host harness that asserts the real
  render trees (18 assertions).
