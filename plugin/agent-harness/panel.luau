--!nonstrict
-- The composer. The only place an agent is launched.
--
-- Enter        -> write the prompt to a file, generate a launch script, open the terminal
-- Alt+Return   -> one-shot: run the agent's print mode and render the answer here
-- Escape       -> handled by the host (a panel cannot capture the Cancel action)

local agents = require("./lib/agents.luau")
local launch = require("./lib/launch.luau")
local sessions = require("./lib/sessions.luau")
local state = require("./lib/state.luau")

local status = state.emptyStatus()

local ui_state = {
  agentId = "pi",
  text = "",
  prompt = "",     -- the submitted prompt, echoed in the result view
  cwd = "",
  model = "",
  provider = "",
  thinking = "",
  continueSession = false,
  approve = false,
  busy = false,
  startedAt = nil,
  output = nil,
  error = nil,
  resolved = {},   -- id -> { adapter, path, available }
}

-- ── helpers ──────────────────────────────────────────────────────────────────

local function entryFor(id)
  for _, agent in ipairs(status.agents or {}) do
    if agent.id == id then
      return agent
    end
  end
  return nil
end

local function resolveAll()
  ui_state.resolved = {}
  for _, adapter in ipairs(agents.list()) do
    local path = launch.resolveBinary(adapter.detect)
    ui_state.resolved[adapter.id] = { adapter = adapter, path = path, available = path ~= nil }
  end
end

local function current()
  return ui_state.resolved[ui_state.agentId]
end

local function refreshSessionLabel()
  local entry = current()
  if entry == nil or not entry.available then
    return nil
  end
  local session = sessions.newest(entry.adapter, launch.expandCwd(ui_state.cwd))
  return sessions.describe(session)
end

local function setError(message)
  ui_state.error = message
  render()
end

-- ── launch ───────────────────────────────────────────────────────────────────

-- promptFile is written by the caller; launch.compose rejects an options table without it.
local function launchOptions(oneShot, promptFile)
  return {
    promptFile = promptFile,
    cwd = launch.expandCwd(ui_state.cwd),
    terminal = noctalia.getConfig("terminal") or "kitty",
    windowClass = noctalia.getConfig("window_class") or "agent-harness",
    model = ui_state.model,
    provider = ui_state.provider,
    thinking = ui_state.thinking,
    approve = ui_state.approve,
    continue = ui_state.continueSession,
    oneShot = oneShot,
  }
end

local function doLaunch()
  local entry = current()
  if entry == nil then
    return setError("Unknown agent")
  end
  if not entry.available then
    return setError(entry.adapter.label .. " is not installed")
  end
  if ui_state.text == "" then
    return setError("Type a prompt first")
  end
  if status.hyprland == false then
    return setError("hyprctl is unavailable, so the terminal cannot be launched")
  end

  local promptFile, perr = launch.writePromptFile(ui_state.text)
  if promptFile == nil then
    return setError(perr)
  end

  local scriptPath, serr = launch.writeLaunchScript(entry.adapter, launchOptions(false, promptFile), entry.path)
  if scriptPath == nil then
    return setError(serr)
  end

  noctalia.runAsync(launch.launchArgv(scriptPath), function(result)
    if result ~= nil and result.exitCode ~= 0 then
      noctalia.notifyError("Agent Harness", "launch failed: " .. tostring(result.stderr or ""))
    end
  end, 5000)

  noctalia.state.set(state.KEY_LAST, { agent = entry.adapter.id, at = math.floor(noctalia.nowMs() / 1000) })
  panel.close()
end

local function doOneShot()
  local entry = current()
  if entry == nil or not entry.available then
    return setError("Agent unavailable")
  end
  if ui_state.text == "" then
    return setError("Type a prompt first")
  end
  if ui_state.busy then
    return
  end

  local promptFile, perr = launch.writePromptFile(ui_state.text)
  if promptFile == nil then
    return setError(perr)
  end

  local scriptPath, serr = launch.writeLaunchScript(entry.adapter, launchOptions(true, promptFile), entry.path)
  if scriptPath == nil then
    return setError(serr)
  end

  ui_state.busy = true
  ui_state.startedAt = noctalia.nowMs()
  ui_state.prompt = ui_state.text
  ui_state.output = nil
  ui_state.error = nil
  noctalia.setUpdateInterval(1000)
  render()

  noctalia.runAsync({ "sh", scriptPath }, function(result)
    ui_state.busy = false
    ui_state.startedAt = nil
    noctalia.setUpdateInterval(60000) -- stop ticking once the run is done
    if result == nil then
      ui_state.error = "one-shot run failed"
    elseif result.timedOut then
      ui_state.error = "one-shot run timed out"
    elseif result.exitCode ~= 0 then
      ui_state.error = tostring(result.stderr or "agent exited with an error")
    else
      ui_state.output = result.stdout or ""
      if ui_state.output == "" then
        ui_state.error = "the agent returned no output"
      end
    end
    render()
  end, 120000)
end

-- ── render ───────────────────────────────────────────────────────────────────

-- Result view: the answer owns the panel. The composer collapses to a single header row so a
-- long answer is not squeezed into a few pixels.
local function renderResult(entry, label)
  local children = {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = entry and entry.adapter.glyph or "robot", size = 15, color = "primary" }),
      ui.label({ text = label, fontWeight = "bold" }),
      ui.spacer({ flexGrow = 1 }),
      ui.button({
        key = "new-prompt",
        text = "New prompt",
        glyph = "plus",
        variant = "secondary",
        onClick = function()
          ui_state.output = nil
          ui_state.error = nil
          ui_state.prompt = ""
          render()
        end,
      }),
      ui.button({ key = "close", text = "Close", variant = "ghost", onClick = function()
        panel.close()
      end }),
    }),
  }

  if ui_state.prompt ~= "" then
    table.insert(children, ui.label({
      text = "› " .. ui_state.prompt,
      color = "on_surface/0.6",
      fontSize = 12,
      maxLines = 1,
    }))
  end

  if ui_state.busy then
    local elapsed = 0
    if ui_state.startedAt ~= nil then
      elapsed = math.floor((noctalia.nowMs() - ui_state.startedAt) / 1000)
    end
    table.insert(children, ui.column({ flexGrow = 1, align = "center", justify = "center", gap = 8 }, {
      ui.glyph({ name = "loader-2", size = 26, color = "primary" }),
      ui.label({ text = string.format("%s is working… %ds", label, elapsed), color = "on_surface/0.7" }),
      ui.label({ text = "Esc closes · the run continues", color = "on_surface/0.4", fontSize = 12 }),
    }))
  else
    -- No stickToBottom: an answer arrives all at once, so the reader wants the top of it.
    table.insert(children, ui.scroll({ flexGrow = 1 }, {
      ui.markdown({ text = ui_state.output or "" }),
    }))
  end

  if ui_state.error ~= nil then
    table.insert(children, ui.label({ text = ui_state.error, color = "error", fontSize = 12 }))
  end

  panel.render(ui.column({ padding = 16, gap = 12, flexGrow = 1 }, children))
end

function render()
  local activeEntry = current()
  local activeLabel = activeEntry ~= nil and activeEntry.adapter.label or ui_state.agentId
  if ui_state.output ~= nil or ui_state.busy then
    renderResult(activeEntry, activeLabel)
    return
  end

  local children = {}

  -- Agent chips
  local chips = {}
  for _, adapter in ipairs(agents.list()) do
    local entry = ui_state.resolved[adapter.id]
    local available = entry ~= nil and entry.available
    table.insert(chips, ui.button({
      key = "agent-" .. adapter.id,
      text = adapter.label,
      glyph = adapter.glyph,
      variant = ui_state.agentId == adapter.id and "primary" or "ghost",
      enabled = available,
      tooltip = available and nil or "not installed",
      onClick = function()
        ui_state.agentId = adapter.id
        ui_state.output = nil
        ui_state.error = nil
        render()
      end,
    }))
  end
  table.insert(children, ui.row({ gap = 8, align = "center" }, chips))

  -- Composer
  table.insert(children, ui.input({
    key = "prompt",
    placeholder = "Ask " .. (entryFor(ui_state.agentId) and entryFor(ui_state.agentId).label or "the agent") .. " to do something…",
    multiline = true,
    submitOnEnter = true,
    focus = true,
    height = 96,
    onChange = function(value)
      ui_state.text = value
    end,
    onSubmit = function(value)
      ui_state.text = value
      doLaunch()
    end,
  }))

  -- Context
  local context = {
    ui.input({
      key = "cwd",
      placeholder = "working directory",
      value = ui_state.cwd,
      flexGrow = 1,
      onChange = function(value)
        ui_state.cwd = value
      end,
    }),
  }
  table.insert(children, ui.row({ gap = 8, align = "center" }, context))

  local entry = current()
  local caps = entry ~= nil and entry.adapter.capabilities or {}
  local options = {}
  if caps.model then
    table.insert(options, ui.input({
      key = "model",
      placeholder = "model (optional)",
      value = ui_state.model,
      width = 200,
      onChange = function(value)
        ui_state.model = value
      end,
    }))
  end
  if caps.provider then
    table.insert(options, ui.input({
      key = "provider",
      placeholder = "provider (optional)",
      value = ui_state.provider,
      width = 160,
      onChange = function(value)
        ui_state.provider = value
      end,
    }))
  end
  table.insert(options, ui.toggle({
    key = "continue",
    checked = ui_state.continueSession,
    onChange = function(value)
      ui_state.continueSession = value == "true"
      render()
    end,
  }))
  table.insert(options, ui.label({ text = "continue", color = "on_surface/0.7" }))
  if caps.approve then
    table.insert(options, ui.toggle({
      key = "approve",
      checked = ui_state.approve,
      onChange = function(value)
        ui_state.approve = value == "true"
      end,
    }))
    table.insert(options, ui.label({ text = "approve files", color = "on_surface/0.7" }))
  end
  table.insert(children, ui.row({ gap = 8, align = "center" }, options))

  -- Status line
  local hint
  if ui_state.error ~= nil then
    hint = ui_state.error
  elseif ui_state.busy then
    hint = "running one-shot…"
  else
    local sessionLabel = refreshSessionLabel()
    hint = "Enter: open terminal  ·  Alt+Enter: answer here"
    if ui_state.continueSession then
      hint = hint .. "  ·  " .. (sessionLabel and ("resume " .. sessionLabel) or "no session to resume")
    end
  end
  table.insert(children, ui.label({ text = hint, color = "on_surface/0.6", fontSize = 12 }))

  panel.render(ui.column({ padding = 16, gap = 12, flexGrow = 1 }, children))
end

-- Panels receive update() on the configured interval; use it to advance the elapsed counter.
function update()
  if ui_state.busy then
    render()
  end
end

-- ── lifecycle ────────────────────────────────────────────────────────────────

function onOpen(context)
  status = state.migrate(noctalia.state.get(state.KEY_STATUS))
  resolveAll()
  ui_state.agentId = noctalia.getConfig("default_agent") or "pi"
  ui_state.cwd = noctalia.getConfig("default_cwd") or "~/work"
  ui_state.approve = noctalia.getConfig("approve_project_files") == true
  ui_state.output = nil
  ui_state.error = nil
  render()
end

function onKey(chord, pressed)
  if not pressed then
    return
  end
  if chord == "alt+Return" or chord == "alt+enter" then
    doOneShot()
  end
end

function onIpc(event, payload)
  if event == "set-prompt" and type(payload) == "string" then
    ui_state.text = payload
    render()
  end
end

noctalia.state.watch(state.KEY_STATUS, function(value)
  status = state.migrate(value)
  resolveAll()
  render()
end)
