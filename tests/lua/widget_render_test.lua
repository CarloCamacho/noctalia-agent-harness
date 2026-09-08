--!nonstrict
-- Render-tree tests for the bar widget, run against the real entry script.
--
-- Run from the repo root:  lua5.4 tests/lua/widget_render_test.lua

package.path = "tests/lua/?.lua;" .. package.path
local H = dofile("tests/lua/harness.lua")

H.stateValue = {
  schema = 1,
  updatedAt = 0,
  agents = {
    { id = "pi", label = "Pi", glyph = "math-pi", available = true, verified = true,
      path = "/x/pi", capabilities = {} },
    { id = "hermes", label = "Hermes", glyph = "sparkles", available = true, verified = true,
      path = "/x/hermes", capabilities = {} },
  },
  running = { pi = true },
  hyprland = true,
}
H.config.agent = "pi"
H.config.glyph = ""
H.config.show_label = false

H.install("plugin/agent-harness")
H.load("widget.luau")

local failures = 0
local function check(name, condition, detail)
  if condition then
    print("ok   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. (detail ~= nil and ("  -- " .. tostring(detail)) or ""))
  end
end

local glyph = H.find(H.tree, H.byType("glyph"))
check("widget renders a glyph", glyph ~= nil)
check("default glyph follows the agent", glyph ~= nil and glyph.props.name == "math-pi",
  glyph ~= nil and glyph.props.name)
check("running agent uses the accent colour", glyph ~= nil and glyph.props.color == "primary",
  glyph ~= nil and glyph.props.color)
check("no label unless asked", H.find(H.tree, H.byType("label")) == nil)

-- Per-instance override
H.config.glyph = "robot"
update()
glyph = H.find(H.tree, H.byType("glyph"))
check("glyph override wins", glyph ~= nil and glyph.props.name == "robot",
  glyph ~= nil and glyph.props.name)

-- Label toggle
H.config.glyph = ""
H.config.show_label = true
update()
check("label appears when enabled", H.text(H.tree):find("Pi") ~= nil, H.text(H.tree))

-- Unavailable agent dims the widget
H.stateValue.agents[1].available = false
H.stateValue.running = {}
update()
glyph = H.find(H.tree, H.byType("glyph"))
check("unavailable agent is dimmed", glyph ~= nil and glyph.props.color == "on_surface/0.5",
  glyph ~= nil and glyph.props.color)

print(string.format("\n%s -- %d failure(s)", failures == 0 and "ALL PASS" or "FAILURES", failures))
os.exit(failures == 0 and 0 or 1)
