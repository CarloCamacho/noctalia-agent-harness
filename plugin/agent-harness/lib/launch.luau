--!nonstrict
-- Launch composition.
--
-- Security model: the prompt is never part of a command string. It is written to a file, and
-- the command that reaches the shell contains only generated paths and validated enums.
--
-- Verified on this machine (docs/phase0-findings.md):
--   * `hyprctl dispatch 'hl.dsp.exec_cmd("...")'` runs the string through a shell
--   * `hyprctl eval 'hl.window_rule({...})'` applies a rule to new windows at runtime
--   * the compositor's exec PATH does NOT include the agent runtime, so the script sets PATH

local agents = require("./agents.luau")

local M = {}

local PROMPT_TTL_MS = 10 * 60 * 1000 -- 10 minutes

local function append(target, values)
  for _, value in ipairs(values) do
    table.insert(target, value)
  end
  return target
end

-- Window classes must be safe both in a shell argument and inside a Lua regex literal.
local function sanitizeClass(value)
  local cleaned = tostring(value or ""):gsub("[^%w%-_]", "")
  if cleaned == "" then
    cleaned = "agent-harness"
  end
  return cleaned
end

-- ── quoting ──────────────────────────────────────────────────────────────────

function M.shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

function M.shellArgv(argv)
  local out = {}
  for _, value in ipairs(argv) do
    table.insert(out, M.shellQuote(value))
  end
  return table.concat(out, " ")
end

-- ── environment ──────────────────────────────────────────────────────────────

-- The Noctalia daemon runs with a bare system PATH (verified live: no ~/.local/bin, no
-- pi-node). We search, in order: known per-user locations, a probed login-shell PATH, then
-- the daemon PATH. The probe augments the list; it never replaces it, because the daemon's
-- `sh -lc` does not source fish config and can therefore be narrower than the real user PATH.
local probedPath = nil

function M.setSearchPath(path)
  if type(path) == "string" and path ~= "" then
    probedPath = path
  end
end

function M.searchDirs()
  local dirs = {}
  local seen = {}
  local function add(dir)
    if type(dir) == "string" and dir ~= "" and not seen[dir] then
      seen[dir] = true
      table.insert(dirs, dir)
    end
  end

  local home = M.homeDir()
  if home ~= "" then
    add(home .. "/.local/bin")
    -- Pi ships its own Node runtime under a versioned directory.
    local piRoot = home .. "/.local/share/pi-node"
    local versions = noctalia.listDir(piRoot)
    if type(versions) == "table" then
      for _, name in ipairs(versions) do
        add(piRoot .. "/" .. name .. "/bin")
      end
    end
  end
  for dir in (probedPath or ""):gmatch("[^:]+") do
    add(dir)
  end
  for dir in (noctalia.getenv("PATH") or ""):gmatch("[^:]+") do
    add(dir)
  end
  return dirs
end

-- Resolve an executable through the search path without spawning a process.
function M.resolveBinary(name)
  if type(name) ~= "string" or name == "" then
    return nil
  end
  if name:find("/") then
    if noctalia.fileExists(name) then
      return name
    end
    return nil
  end
  for _, dir in ipairs(M.searchDirs()) do
    local candidate = dir .. "/" .. name
    if noctalia.fileExists(candidate) then
      local info = noctalia.fileInfo(candidate)
      if info ~= nil and not info.isDir then
        return candidate
      end
    end
  end
  return nil
end

-- The directory holding the agent binary also holds its runtime (pi ships its own node).
function M.runtimePrefix(binaryPath)
  if type(binaryPath) ~= "string" then
    return ""
  end
  local dir = binaryPath:match("^(.*)/[^/]+$")
  return dir or ""
end

function M.homeDir()
  return noctalia.getenv("HOME") or ""
end

function M.expandCwd(path)
  if type(path) ~= "string" or path == "" then
    return M.homeDir()
  end
  if path:sub(1, 1) == "~" then
    return M.homeDir() .. path:sub(2)
  end
  return path
end

-- ── generated files ──────────────────────────────────────────────────────────

local function newToken()
  math.randomseed(noctalia.nowMs() % 2147483647)
  return string.format("%x%x", noctalia.nowMs(), math.random(0, 0xFFFFFF))
end

function M.dataDir(sub)
  local base = noctalia.pluginDataDir()
  if type(base) ~= "string" or base == "" then
    return nil, "plugin data directory unavailable"
  end
  local dir = sub and (base .. "/" .. sub) or base
  if not noctalia.fileExists(dir) then
    local ok, err = noctalia.mkdirAll(dir)
    if not ok then
      return nil, err or "cannot create " .. dir
    end
  end
  return dir
end

function M.writePromptFile(text)
  local dir, err = M.dataDir("prompts")
  if dir == nil then
    return nil, err
  end
  local path = dir .. "/" .. newToken() .. ".txt"
  local ok, werr = noctalia.writeFile(path, text)
  if not ok then
    return nil, werr or "cannot write prompt file"
  end
  return path
end

-- ── command composition ──────────────────────────────────────────────────────

-- Build the agent argv plus the prompt expression. The prompt expression is the only place
-- the prompt file is referenced, and it is either `"$(cat '<file>')"` or `--query-file '<file>'`.
function M.compose(adapter, opts)
  local valid, verr = agents.validate(adapter)
  if not valid then
    return nil, verr
  end
  if type(opts.promptFile) ~= "string" or opts.promptFile == "" then
    return nil, "missing prompt file"
  end

  local argv
  if opts.oneShot and adapter.oneShot ~= nil then
    argv = adapter.oneShot(opts)
  else
    argv = adapter.build(opts)
  end

  local promptExpr
  if adapter.delivery == "cat-file" then
    promptExpr = '"$(cat ' .. M.shellQuote(opts.promptFile) .. ')"'
  else
    table.insert(argv, "--query-file")
    promptExpr = M.shellQuote(opts.promptFile)
  end

  return { argv = argv, promptExpr = promptExpr, delivery = adapter.delivery }
end

-- Wrap an inner command in the configured terminal, tagging the window with our class so the
-- runtime window rule matches. `-e` is the separator kitty, alacritty and ghostty all accept.
function M.terminalArgv(termBin, class, cwd, innerArgv)
  local name = tostring(termBin or "kitty")
  local argv = { name }
  local cls = sanitizeClass(class)
  if name:match("kitty") then
    append(argv, { "--class", cls, "--directory", cwd })
  elseif name:match("alacritty") then
    append(argv, { "--class", cls, "--working-directory", cwd })
  elseif name:match("ghostty") then
    append(argv, { "--class=" .. cls, "--working-directory=" .. cwd })
  end
  table.insert(argv, "-e")
  for _, value in ipairs(innerArgv) do
    table.insert(argv, value)
  end
  return argv
end

function M.scriptContents(adapter, opts, composed, binaryPath)
  local lines = {
    "#!/bin/sh",
    "# generated by carlocamacho/agent-harness - safe to delete",
  }

  -- The pop-out shell gets the agent's own runtime directory, ~/.local/bin, and the basics.
  local parts = {}
  local prefix = M.runtimePrefix(binaryPath)
  if prefix ~= "" then
    table.insert(parts, prefix)
  end
  local home = M.homeDir()
  if home ~= "" then
    table.insert(parts, home .. "/.local/bin")
  end
  table.insert(parts, "/usr/local/bin")
  table.insert(parts, "/usr/bin")
  table.insert(parts, "/bin")
  table.insert(lines, "PATH=" .. M.shellQuote(table.concat(parts, ":")))
  table.insert(lines, "export PATH")

  local cwd = M.expandCwd(opts.cwd)
  if cwd ~= "" then
    table.insert(lines, "cd " .. M.shellQuote(cwd) .. " || exit 1")
  end

  local argv = {}
  for i, value in ipairs(composed.argv) do
    argv[i] = value
  end
  if binaryPath ~= nil and binaryPath ~= "" then
    argv[1] = binaryPath
  end

  local execArgv
  if opts.oneShot then
    -- One-shot captures stdout, so it must NOT be wrapped in a terminal.
    execArgv = argv
  else
    execArgv = M.terminalArgv(opts.terminal, opts.windowClass, cwd, argv)
    if noctalia.commandExists("uwsm-app") then
      table.insert(execArgv, 1, "uwsm-app")
      table.insert(execArgv, 2, "--")
    end
  end

  table.insert(lines, "exec " .. M.shellArgv(execArgv) .. " " .. composed.promptExpr)
  return table.concat(lines, "\n") .. "\n"
end

function M.writeLaunchScript(adapter, opts, binaryPath)
  local composed, cerr = M.compose(adapter, opts)
  if composed == nil then
    return nil, cerr
  end
  local dir, derr = M.dataDir("launch")
  if dir == nil then
    return nil, derr
  end
  local path = dir .. "/" .. newToken() .. ".sh"
  local ok, werr = noctalia.writeFile(path, M.scriptContents(adapter, opts, composed, binaryPath))
  if not ok then
    return nil, werr or "cannot write launch script"
  end
  return path, nil, composed
end

-- ── hyprland ─────────────────────────────────────────────────────────────────

local function safeClass(class)
  return sanitizeClass(class)
end

function M.windowClass(class)
  return safeClass(class)
end

function M.windowRuleLua(class, width, height, enabled)
  local cls = safeClass(class)
  if not enabled then
    return string.format('hl.window_rule({ match = { class = "^%s$" }, float = false })', cls)
  end
  return string.format(
    'hl.window_rule({ match = { class = "^%s$" }, float = true, center = true, size = { "%d", "%d" } })',
    cls,
    math.floor(tonumber(width) or 900),
    math.floor(tonumber(height) or 600)
  )
end

-- Only generated script paths reach this, so escaping stays trivial and auditable.
function M.execCmdLua(command)
  local escaped = tostring(command):gsub("\\", "\\\\"):gsub('"', '\\"')
  return 'hl.dsp.exec_cmd("' .. escaped .. '")'
end

function M.launchArgv(scriptPath)
  return { "hyprctl", "dispatch", M.execCmdLua("sh " .. scriptPath) }
end

function M.windowRuleArgv(luaExpr)
  return { "hyprctl", "eval", luaExpr }
end

-- ── maintenance ──────────────────────────────────────────────────────────────

-- `fileInfo().mtime` unit is not documented; normalise seconds vs milliseconds.
local function ageMs(mtime)
  local now = noctalia.nowMs()
  local stamp = tonumber(mtime) or 0
  if stamp > 1e12 then
    return now - stamp
  end
  return now - (stamp * 1000)
end

-- Delete generated prompt/launch files older than the TTL. Never called immediately after a
-- launch: the shell may not have read the file yet.
function M.sweep(sub, maxAgeMs)
  local dir = M.dataDir(sub)
  if dir == nil then
    return 0
  end
  local listing = noctalia.listDir(dir)
  if type(listing) ~= "table" then
    return 0
  end
  local ttl = maxAgeMs or PROMPT_TTL_MS
  local removed = 0
  for _, name in ipairs(listing) do
    local path = dir .. "/" .. name
    local info = noctalia.fileInfo(path)
    if info ~= nil and not info.isDir and ageMs(info.mtime) > ttl then
      noctalia.removeFile(path)
      removed = removed + 1
    end
  end
  return removed
end

function M.sweepAll()
  return M.sweep("prompts") + M.sweep("launch")
end

return M
