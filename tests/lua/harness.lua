-- Minimal Noctalia host stub so a plugin entry can be loaded and driven under plain Lua 5.4.
--
-- This is not a Noctalia emulator. It implements exactly the host surface the entries use, so
-- render trees can be asserted deterministically in CI without a running shell.
--
-- Usage:
--   local H = dofile("tests/lua/harness.lua")
--   H.install("plugin/agent-harness")
--   local panel = H.load("panel.luau")

local H = {}

H.config = {
  default_agent = "pi",
  terminal = "kitty",
  window_class = "agent-harness",
  default_cwd = "/tmp/work",
  float_window = true,
  float_width = 900,
  float_height = 600,
  approve_project_files = false,
}

H.env = { HOME = "/home/tester", PATH = "/usr/bin:/bin" }
H.tree = nil
H.closed = false
H.commands = {}
H.pending = {}   -- pending runAsync callbacks, in order
H.logs = {}
H.files = {}     -- path -> contents written

local function noop() end

-- Noctalia resolves each require() relative to the file that contains the call, so the harness
-- tracks the directory of the file currently being loaded.
local dirStack = {}

local function normalize(path)
  path = path:gsub("/%.%/", "/")
  path = path:gsub("//+", "/")
  return path
end

function H.install(plugin_dir)
  H.plugin_dir = plugin_dir
  H.tree = nil
  H.closed = false
  H.commands = {}
  H.pending = {}
  H.logs = {}
  H.files = {}

  _G.noctalia = {
    log = function(msg)
      table.insert(H.logs, tostring(msg))
    end,
    nowMs = function()
      return 1000000
    end,
    getConfig = function(key)
      return H.config[key]
    end,
    getenv = function(name)
      return H.env[name]
    end,
    expandPath = function(path)
      return path
    end,
    -- Pretend the two shipped agents are installed, and that the plugin data dir exists.
    fileExists = function(path)
      if path:match("/pi$") or path:match("/hermes$") then
        return true
      end
      return path:match("^/tmp/agent%-harness%-data") ~= nil
    end,
    fileInfo = function(path)
      if path:match("/pi$") or path:match("/hermes$") then
        return { size = 1, mtime = 0, isDir = false }
      end
      if path:match("^/tmp/agent%-harness%-data") then
        return { size = 0, mtime = 0, isDir = true }
      end
      return nil
    end,
    listDir = function()
      return {}
    end,
    pluginDataDir = function()
      return "/tmp/agent-harness-data"
    end,
    mkdirAll = function()
      return true
    end,
    writeFile = function(path, contents)
      H.files[path] = contents
      return true
    end,
    removeFile = function()
      return true
    end,
    renameFile = function()
      return true
    end,
    commandExists = function()
      return true
    end,
    notify = noop,
    notifyError = noop,
    copyToClipboard = function()
      return true
    end,
    setUpdateInterval = noop,
    togglePanel = noop,
    processMatches = function(cb)
      if cb then
        cb(false)
      end
      return true
    end,
    runAsync = function(cmd, cb)
      table.insert(H.commands, cmd)
      if cb then
        table.insert(H.pending, cb)
      end
      return true
    end,
    runStream = function()
      return true
    end,
    http = function()
      return true
    end,
    formatTime = function()
      return "12:00"
    end,
    state = {
      get = function()
        return nil
      end,
      set = noop,
      watch = noop,
    },
    json = {
      decode = function()
        return nil
      end,
      encode = function()
        return ""
      end,
    },
    string = {
      trim = function(s)
        return (tostring(s):gsub("^%s+", ""):gsub("%s+$", ""))
      end,
    },
  }

  -- ui.* constructors return plain trees.
  _G.ui = setmetatable({}, {
    __index = function(_, kind)
      return function(props, children)
        return { type = kind, props = props or {}, children = children or {} }
      end
    end,
  })

  _G.panel = {
    render = function(tree)
      H.tree = tree
    end,
    close = function()
      H.closed = true
    end,
    openContextMenu = function()
      return false
    end,
    setWantsSecondTicks = noop,
    setNeedsFrameTick = noop,
  }

  _G.barWidget = {
    render = function(tree)
      H.tree = tree
    end,
    setText = noop,
    setGlyph = noop,
    setTooltip = noop,
    clearTooltip = noop,
    setColor = noop,
    setVisible = noop,
    isVertical = function()
      return false
    end,
    outputName = function()
      return "DP-1"
    end,
  }

  _G.shortcut = { setLabel = noop, setIcon = noop, setActive = noop, setEnabled = noop }
  _G.launcher = { setResults = noop, setQuery = noop }
  _G.desktopWidget = { render = noop, setWantsSecondTicks = noop, setNeedsFrameTick = noop }

  -- Resolve plugin-relative requires against the directory of the calling file.
  local realRequire = require
  _G.require = function(name)
    if type(name) == "string" and name:sub(1, 2) == "./" then
      local base = dirStack[#dirStack] or H.plugin_dir
      local path = normalize(base .. "/" .. name:sub(3))
      local chunk, err = loadfile(path)
      if chunk == nil then
        error("require failed for " .. path .. ": " .. tostring(err))
      end
      table.insert(dirStack, path:match("^(.*)/[^/]+$") or ".")
      local ok, result = pcall(chunk)
      table.remove(dirStack)
      if not ok then
        error(result)
      end
      return result
    end
    return realRequire(name)
  end
end

function H.load(entry)
  local path = H.plugin_dir .. "/" .. entry
  local chunk, err = loadfile(path)
  if chunk == nil then
    error("loadfile failed: " .. tostring(err))
  end
  table.insert(dirStack, path:match("^(.*)/[^/]+$") or ".")
  local ok, result = pcall(chunk)
  table.remove(dirStack)
  if not ok then
    error(result)
  end
  return result
end

-- Depth-first search for the first node matching `pred`.
function H.find(node, pred)
  if node == nil then
    return nil
  end
  if pred(node) then
    return node
  end
  for _, child in ipairs(node.children or {}) do
    local hit = H.find(child, pred)
    if hit ~= nil then
      return hit
    end
  end
  return nil
end

function H.findAll(node, pred, out)
  out = out or {}
  if node == nil then
    return out
  end
  if pred(node) then
    table.insert(out, node)
  end
  for _, child in ipairs(node.children or {}) do
    H.findAll(child, pred, out)
  end
  return out
end

function H.byType(kind)
  return function(node)
    return node.type == kind
  end
end

function H.text(node)
  local parts = {}
  local function walk(n)
    if n == nil then
      return
    end
    if n.props and n.props.text then
      table.insert(parts, tostring(n.props.text))
    end
    if n.props and n.props.name then
      table.insert(parts, tostring(n.props.name))
    end
    for _, child in ipairs(n.children or {}) do
      walk(child)
    end
  end
  walk(node)
  return table.concat(parts, " | ")
end

return H
