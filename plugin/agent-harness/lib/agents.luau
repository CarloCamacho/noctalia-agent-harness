--!nonstrict
-- Agent adapters — the extension seam.
--
-- Every adapter is code, not user data. Adding an agent means adding one table here.
-- The prompt never appears in a command string: `launch.luau` writes it to a file and the
-- adapter declares how that file reaches the agent (`cat-file` or `flag-file`).
--
-- Verified against the real CLIs on 2026-09-08 (see docs/phase0-findings.md):
--   pi     0.85.1  `pi "<prompt>"` submits the prompt as the first turn of an interactive
--                  session (confirmed in the session JSONL); `-p` is one-shot.
--   hermes         `hermes chat --query-file <path>` reads the file byte-identically and
--                  seeds an interactive session on a real TTY; `-z` is one-shot.

local M = {}

local function append(argv, extra)
  for _, value in ipairs(extra) do
    table.insert(argv, value)
  end
  return argv
end

M.adapters = {
  pi = {
    id = "pi",
    label = "Pi",
    glyph = "math-pi",
    detect = "pi",
    verified = true,
    -- The prompt is appended as `"$(cat '<file>')"` by launch.luau.
    delivery = "cat-file",
    capabilities = {
      model = true,
      thinking = true,
      continue = true,
      approve = true,
    },
    -- Build the agent argv. The prompt is NOT part of this; launch.luau appends it.
    build = function(opts)
      local argv = { "pi" }
      if opts.model and opts.model ~= "" then
        append(argv, { "--model", opts.model })
      end
      if opts.thinking and opts.thinking ~= "" then
        append(argv, { "--thinking", opts.thinking })
      end
      if opts.approve then
        table.insert(argv, "--approve")
      end
      if opts.sessionId and opts.sessionId ~= "" then
        append(argv, { "--session", opts.sessionId })
      elseif opts.continue then
        table.insert(argv, "--continue")
      end
      return argv
    end,
    oneShot = function(opts)
      local argv = { "pi", "--print" }
      if opts.model and opts.model ~= "" then
        append(argv, { "--model", opts.model })
      end
      return argv
    end,
    -- Per-project session store: ~/.pi/agent/sessions/--<encoded-cwd>--/
    sessionDir = function(home, cwd)
      return home .. "/.pi/agent/sessions/" .. M.encodeCwd(cwd)
    end,
  },

  hermes = {
    id = "hermes",
    label = "Hermes",
    glyph = "sparkles",
    detect = "hermes",
    verified = true,
    -- launch.luau appends `--query-file '<file>'`.
    delivery = "flag-file",
    capabilities = {
      model = true,
      provider = true,
      continue = true,
      approve = false,
    },
    build = function(opts)
      local argv = { "hermes", "chat" }
      if opts.model and opts.model ~= "" then
        append(argv, { "-m", opts.model })
      end
      if opts.provider and opts.provider ~= "" then
        append(argv, { "--provider", opts.provider })
      end
      if opts.sessionId and opts.sessionId ~= "" then
        append(argv, { "--resume", opts.sessionId })
      elseif opts.continue then
        table.insert(argv, "--continue")
      end
      return argv
    end,
    oneShot = function(opts)
      local argv = { "hermes", "-z" }
      if opts.model and opts.model ~= "" then
        append(argv, { "-m", opts.model })
      end
      return argv
    end,
    sessionDir = function()
      -- Hermes keeps sessions in its own store; resolving "last session" is deferred.
      return nil
    end,
  },
}

M.order = { "pi", "hermes" }

-- Pi encodes a cwd as `--<path, leading slash dropped, / replaced by ->--`.
-- /home/ian/work/agent-harness/scratch -> --home-ian-work-agent-harness-scratch--
function M.encodeCwd(cwd)
  local trimmed = tostring(cwd or ""):gsub("/+$", "")
  local stripped = trimmed:gsub("^/+", "")
  if stripped == "" then
    return "--"
  end
  return "--" .. stripped:gsub("/", "-") .. "--"
end

function M.get(id)
  return M.adapters[id]
end

function M.list()
  local out = {}
  for _, id in ipairs(M.order) do
    table.insert(out, M.adapters[id])
  end
  return out
end

-- Reject an adapter whose fixed argv could escape into a shell. The prompt is never in
-- this list, so a metacharacter here means the adapter table itself is wrong.
local META = "[;|&$`<>(){}%[%]!*?~\"'\n\r]"
function M.validate(adapter)
  if type(adapter) ~= "table" then
    return false, "adapter is not a table"
  end
  if adapter.delivery ~= "cat-file" and adapter.delivery ~= "flag-file" then
    return false, "unknown delivery: " .. tostring(adapter.delivery)
  end
  for _, field in ipairs({ "id", "label", "detect" }) do
    if type(adapter[field]) ~= "string" or adapter[field] == "" then
      return false, "missing " .. field
    end
  end
  if adapter.detect:find(META) then
    return false, "detect contains shell metacharacters"
  end
  return true
end

return M
