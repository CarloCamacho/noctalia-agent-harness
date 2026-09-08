--!nonstrict
-- Agent Harness service.
--
-- Owns adapter resolution, running-state detection, the Hyprland window rule, and generated
-- file cleanup. It never launches an agent itself; the panel is the only launcher, because it
-- holds the user's intent (prompt + agent + cwd) at the moment Enter is pressed.
--
-- The `launch` IPC event exists so a keybind or script can drive a launch without the panel.

local agents = require("./lib/agents.luau")
local launch = require("./lib/launch.luau")
local state = require("./lib/state.luau")

local status = state.emptyStatus()
local running = {}
local resolved = {}
local config = {}

local function reloadConfig()
  config = {
    defaultAgent = noctalia.getConfig("default_agent") or "pi",
    terminal = noctalia.getConfig("terminal") or "kitty",
    defaultCwd = noctalia.getConfig("default_cwd") or "~/work",
    windowClass = noctalia.getConfig("window_class") or "agent-harness",
    floatWindow = noctalia.getConfig("float_window") ~= false,
    floatWidth = tonumber(noctalia.getConfig("float_width")) or 900,
    floatHeight = tonumber(noctalia.getConfig("float_height")) or 600,
    approve = noctalia.getConfig("approve_project_files") == true,
  }
end

local function publish()
  status.schema = state.SCHEMA
  status.updatedAt = math.floor(noctalia.nowMs() / 1000)
  status.running = running
  noctalia.state.set(state.KEY_STATUS, status)
end

local function resolveAdapters()
  local list = {}
  resolved = {}
  for _, adapter in ipairs(agents.list()) do
    local path = launch.resolveBinary(adapter.detect)
    resolved[adapter.id] = { adapter = adapter, path = path, available = path ~= nil }
    table.insert(list, {
      id = adapter.id,
      label = adapter.label,
      glyph = adapter.glyph,
      available = path ~= nil,
      verified = adapter.verified,
      path = path or "",
      capabilities = adapter.capabilities,
    })
  end
  status.agents = list
  status.hyprland = noctalia.commandExists("hyprctl")
end

local function applyWindowRule()
  if not noctalia.commandExists("hyprctl") then
    status.hyprland = false
    return
  end
  status.hyprland = true
  -- Runtime rules are not persisted across a Hyprland reload, so re-apply on every enable,
  -- config change, and output change.
  local expr = launch.windowRuleLua(config.windowClass, config.floatWidth, config.floatHeight, config.floatWindow)
  noctalia.runAsync(launch.windowRuleArgv(expr), nil, 5000)
end

local function detectRunning()
  for _, adapter in ipairs(agents.list()) do
    local id = adapter.id
    noctalia.processMatches(function(matched)
      if running[id] ~= matched then
        running[id] = matched
        publish()
      end
    end, adapter.detect)
  end
end

-- Shared launch path for the `launch` IPC event. The panel composes its own launch from the
-- same lib functions; this exists for keybinds and scripts.
local function performLaunch(req)
  if type(req) ~= "table" then
    return false, "bad payload"
  end
  local agentId = req.agent or config.defaultAgent
  local entry = resolved[agentId]
  if entry == nil then
    return false, "unknown agent: " .. tostring(agentId)
  end
  if not entry.available then
    return false, entry.adapter.label .. " is not installed"
  end

  local promptFile, perr = launch.writePromptFile(tostring(req.prompt or ""))
  if promptFile == nil then
    return false, perr
  end

  local opts = {
    promptFile = promptFile,
    cwd = req.cwd or config.defaultCwd,
    model = req.model,
    provider = req.provider,
    thinking = req.thinking,
    approve = req.approve == true,
    continue = req.continue == true,
    sessionId = req.sessionId,
  }

  local scriptPath, serr = launch.writeLaunchScript(entry.adapter, opts, entry.path)
  if scriptPath == nil then
    return false, serr
  end

  applyWindowRule()
  noctalia.runAsync(launch.launchArgv(scriptPath), function(result)
    if result ~= nil and result.exitCode ~= 0 then
      noctalia.notifyError("Agent Harness", "launch failed: " .. tostring(result.stderr or ""))
    end
  end, 5000)

  status.lastLaunch = { agent = agentId, at = math.floor(noctalia.nowMs() / 1000) }
  publish()
  return true, nil
end

local function decodePayload(payload)
  if type(payload) == "table" then
    return payload
  end
  if type(payload) == "string" then
    local ok, decoded = pcall(noctalia.json.decode, payload)
    if ok and type(decoded) == "table" then
      return decoded
    end
  end
  return nil
end

-- ── lifecycle ────────────────────────────────────────────────────────────────

function update()
  detectRunning()
end

function onEnable()
  reloadConfig()
  resolveAdapters()
  applyWindowRule()
  launch.sweepAll()
  publish()
end

function onConfigChanged()
  reloadConfig()
  resolveAdapters()
  applyWindowRule()
  publish()
end

function onOutputsChanged()
  applyWindowRule()
end

function onExit(_signal, reason)
  if reason == "disable" or reason == "uninstall" then
    launch.sweepAll()
  end
end

function onIpc(event, payload)
  if event == state.EVENT_REFRESH then
    resolveAdapters()
    publish()
  elseif event == state.EVENT_SWEEP then
    launch.sweepAll()
  elseif event == state.EVENT_LAUNCH then
    local req = decodePayload(payload)
    local ok, err = performLaunch(req)
    if not ok then
      noctalia.notifyError("Agent Harness", tostring(err))
    end
  end
end

noctalia.setUpdateInterval(5000)
