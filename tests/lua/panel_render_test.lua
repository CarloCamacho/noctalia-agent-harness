--!nonstrict
-- Render-tree tests for the panel, run against the real entry script under Lua 5.4.
--
-- These drive the actual code paths (onOpen -> onKey alt+Return -> runAsync callback) and assert
-- the tree handed to panel.render(). They are what caught the layout bug where the answer was
-- squeezed into ~30px and pinned to the bottom of the panel.
--
-- Run from the repo root:  lua5.4 tests/lua/panel_render_test.lua

package.path = "tests/lua/?.lua;" .. package.path
local H = dofile("tests/lua/harness.lua")

H.install("plugin/agent-harness")
H.load("panel.luau")

local failures = 0
local function check(name, condition, detail)
  if condition then
    print("ok   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. (detail ~= nil and ("  -- " .. tostring(detail)) or ""))
  end
end

-- ── composer view ────────────────────────────────────────────────────────────

onOpen({})

local input = H.find(H.tree, H.byType("input"))
check("composer renders a prompt input", input ~= nil)
check("composer input submits on Enter", input ~= nil and input.props.submitOnEnter == true)
check("composer shows the hint line", H.text(H.tree):find("open terminal") ~= nil, H.text(H.tree))

-- ── one-shot through the real key path ───────────────────────────────────────

onIpc("set-prompt", "hello world")
onKey("alt+Return", true)

check("Alt+Return dispatches exactly one run", #H.commands == 1, "#commands=" .. #H.commands)
check("Alt+Return does not close the panel", H.closed == false)

local loader = H.find(H.tree, function(node)
  return node.type == "glyph" and node.props.name == "loader-2"
end)
check("busy view shows a loader", loader ~= nil)
check("busy view shows an elapsed hint", H.text(H.tree):find("working") ~= nil, H.text(H.tree))
check("busy view hides the composer", H.find(H.tree, H.byType("input")) == nil)

-- ── result view ──────────────────────────────────────────────────────────────

local callback = H.pending[1]
check("runAsync callback was captured", callback ~= nil)
if callback ~= nil then
  callback({
    exitCode = 0,
    stdout = "# Answer\n\nline one\nline two\nline three\n",
    stderr = "",
    timedOut = false,
    stdoutTruncated = false,
    stderrTruncated = false,
  })
end

local scroll = H.find(H.tree, H.byType("scroll"))
check("result view has a scroll region", scroll ~= nil)
check("scroll takes the remaining space", scroll ~= nil and scroll.props.flexGrow == 1,
  scroll ~= nil and tostring(scroll.props.flexGrow))
check("scroll is not pinned to the bottom", scroll ~= nil and scroll.props.stickToBottom == nil,
  scroll ~= nil and tostring(scroll.props.stickToBottom))

local markdown = H.find(H.tree, H.byType("markdown"))
check("output is rendered as markdown", markdown ~= nil and markdown.props.text:find("line three") ~= nil)
check("result view offers a new prompt", H.text(H.tree):find("New prompt") ~= nil, H.text(H.tree))
check("result view echoes the prompt", H.text(H.tree):find("hello world") ~= nil, H.text(H.tree))
check("result view hides the composer", H.find(H.tree, H.byType("input")) == nil)
check("result view did not close the panel", H.closed == false)

-- ── empty output is reported, not silently blank ─────────────────────────────

onIpc("set-prompt", "second try")
onKey("alt+Return", true)
local second = H.pending[2]
if second ~= nil then
  second({ exitCode = 0, stdout = "", stderr = "", timedOut = false,
           stdoutTruncated = false, stderrTruncated = false })
end
check("empty output surfaces an error", H.text(H.tree):find("returned no output") ~= nil, H.text(H.tree))

print(string.format("\n%s -- %d failure(s)", failures == 0 and "ALL PASS" or "FAILURES", failures))
os.exit(failures == 0 and 0 or 1)
