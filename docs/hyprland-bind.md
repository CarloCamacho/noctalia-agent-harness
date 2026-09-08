# Hyprland binding and window rules

Verified against **Hyprland 0.56.2**, which uses the Lua config format. The legacy
`hyprctl dispatch exec [float;size …] cmd` syntax is **rejected** on this version
(`']' expected near ';'`), so the plugin uses the Lua dispatcher instead.

## 1. Bind the composer

`~/.config/hypr/config/binds.lua`:

```lua
-- Agent Harness: open the chat composer
hl.bind(mainMod .. " + P",
  hl.dsp.exec_cmd("noctalia msg panel-toggle carlocamacho/agent-harness:compose"),
  { description = "Agent Harness composer" })
```

`mainMod` is whatever your config uses (`SUPER` in the CachyOS default). Pick a chord that does
not collide with an existing bind — check with `hyprctl binds`.

The composer is also reachable from the bar module (left click) and over IPC:

```bash
noctalia msg panel-toggle carlocamacho/agent-harness:compose
```

## 2. The pop-out window rule

The plugin applies this at runtime — you do **not** need to edit your config:

```lua
hl.window_rule({
  match  = { class = "^agent-harness$" },
  float  = true,
  center = true,
  size   = { "900", "600" },
})
```

It runs `hyprctl eval` with that expression on plugin enable, on config change, and when the
output set changes, because runtime rules do not survive a Hyprland reload.

To make it permanent instead, add the same rule to
`~/.config/hypr/config/windowrules.lua` and set the plugin's **Window class** setting to match.
If you change the class in the plugin, change the rule's `match.class` too.

## 3. Launch mechanism

```bash
hyprctl dispatch 'hl.dsp.exec_cmd("sh /path/to/generated-launch-script.sh")'
```

Two properties were verified live and both matter:

1. The string **is** shell-interpreted, so the generated script can use `"$(cat '<file>')"`.
2. The compositor's `exec_cmd` runs with a **minimal PATH** that does not include the agent
   runtime. The generated script therefore sets `PATH` explicitly (Pi ships its own Node
   runtime, which is exactly why `~/.local/bin/pi-agent-launch` exists).

Only the generated script path reaches the Lua string, so escaping stays trivial and auditable.

## 4. Fallback

If `hyprctl` is unavailable the panel refuses to launch and says so, rather than silently
opening a tiled window. `noctalia.runInTerminal()` remains a viable future fallback, but it
wraps the command as `<terminal> -e sh -lc "<cmd>"` and applies no window rules, so the pop-out
would not float or centre.
