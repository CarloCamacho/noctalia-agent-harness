--!nonstrict
-- Bar module. One instance per agent; scroll to switch, click to open the composer.

local state = require("./lib/state.luau")

local status = state.emptyStatus()
local override = nil

local function entryFor(id)
  for _, agent in ipairs(status.agents or {}) do
    if agent.id == id then
      return agent
    end
  end
  return nil
end

local function currentId()
  return override or noctalia.getConfig("agent") or "pi"
end

local function render()
  local id = currentId()
  local agent = entryFor(id)
  local showLabel = noctalia.getConfig("show_label") == true
  local isRunning = status.running ~= nil and status.running[id] == true

  local colour
  if agent == nil or not agent.available then
    colour = "on_surface/0.5"
  elseif isRunning then
    colour = "primary"
  else
    colour = "on_surface"
  end

  -- Per-instance glyph override; empty means "follow the agent's own glyph".
  local override = noctalia.getConfig("glyph")
  if type(override) ~= "string" or override == "" then
    override = nil
  end
  local glyphName = override or (agent and agent.glyph) or "robot"

  local children = { ui.glyph({ name = glyphName, size = 15, color = colour }) }
  if showLabel then
    table.insert(children, ui.label({ text = agent and agent.label or id, color = colour }))
  end
  barWidget.render(ui.row({ gap = 6, align = "center" }, children))

  local rows = {
    { key = "Agent", value = agent and agent.label or (id .. " (unknown)") },
    { key = "State", value = (agent == nil and "not resolved") or (not agent.available and "not installed") or (isRunning and "running") or "idle" },
  }
  if agent ~= nil and agent.path ~= "" then
    table.insert(rows, { key = "Binary", value = agent.path })
  end
  if status.hyprland == false then
    table.insert(rows, { key = "Warning", value = "hyprctl unavailable: window rules disabled" })
  end
  barWidget.setTooltip(rows)
end

function update()
  render()
end

function onClick()
  noctalia.togglePanel("carlocamacho/agent-harness:compose")
end

function onScroll(_axis, steps, startsGesture)
  if not startsGesture then
    return
  end
  local list = status.agents or {}
  if #list == 0 then
    return
  end
  local id = currentId()
  local index = 1
  for i, agent in ipairs(list) do
    if agent.id == id then
      index = i
    end
  end
  index = index + (steps > 0 and 1 or -1)
  if index < 1 then
    index = #list
  elseif index > #list then
    index = 1
  end
  override = list[index].id
  render()
end

noctalia.state.watch(state.KEY_STATUS, function(value)
  status = state.migrate(value)
  render()
end)

status = state.migrate(noctalia.state.get(state.KEY_STATUS))
render()
