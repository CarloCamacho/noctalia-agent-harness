# IPC contract

Entry ids are `carlocamacho/agent-harness:<entry>`. Services are singletons with no output, so
address them with the `all` target.

## Service

| Event | Payload | Effect |
| --- | --- | --- |
| `refresh` | — | Re-resolve adapters (binary presence) and re-publish running state |
| `sweep` | — | Delete generated prompt/launch files older than 10 minutes |
| `launch` | JSON `{ agent, prompt, cwd?, model?, provider?, thinking?, approve?, continue?, sessionId? }` | Full launch without opening the composer. Rejects with a notification when the agent is missing or the payload is malformed |

```bash
noctalia msg plugin carlocamacho/agent-harness:service all launch \
  '{"agent":"pi","prompt":"explain my monitors config","cwd":"~/work"}'
```

The service is the single writer of `agent_harness_status`. The panel composes its own launch
from the same `lib/` functions; the `launch` event exists for keybinds and scripts.

## Panel

| Event | Payload | Effect |
| --- | --- | --- |
| `set-prompt` | plain text | Pre-fills the composer (does not submit) |

```bash
noctalia msg plugin carlocamacho/agent-harness:compose all set-prompt "review the last commit"
noctalia msg panel-toggle carlocamacho/agent-harness:compose
```

## State channel

`agent_harness_status` (schema 1):

```jsonc
{
  "schema": 1,
  "updatedAt": 1788874602,
  "agents": [
    {
      "id": "pi",
      "label": "Pi",
      "glyph": "terminal-2",
      "available": true,
      "verified": true,
      "path": "/home/ian/.local/share/pi-node/…/bin/pi",
      "capabilities": { "model": true, "thinking": true, "continue": true, "approve": true }
    }
  ],
  "running": { "pi": false },
  "hyprland": true,
  "error": ""
}
```

`agent_harness_last_launch` records the most recent launch (`{ agent, at }`) for debugging.

## Generated files

| Path | Contents | Lifetime |
| --- | --- | --- |
| `<pluginDataDir>/prompts/<token>.txt` | the prompt, verbatim | swept after 10 minutes |
| `<pluginDataDir>/launch/<token>.sh` | the composed launch script | swept after 10 minutes |

Files are never deleted immediately after a launch — the shell may not have read them yet.
