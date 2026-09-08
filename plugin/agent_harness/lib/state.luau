--!nonstrict
-- Shared state keys and schema versions.
--
-- Only the service writes; widget and panel read and watch. Bump SCHEMA when a key's shape
-- changes and add a migration in `migrate`.

local M = {}

M.SCHEMA = 1

M.KEY_STATUS = "agent_harness_status"     -- adapters + running state + recents
M.KEY_LAST = "agent_harness_last_launch"  -- most recent launch request (for debugging)

M.EVENT_REFRESH = "refresh"
M.EVENT_LAUNCH = "launch"
M.EVENT_SWEEP = "sweep"

function M.emptyStatus()
  return {
    schema = M.SCHEMA,
    updatedAt = 0,
    agents = {},        -- { { id, label, glyph, available, verified, path, capabilities } }
    running = {},       -- { [agentId] = true }
    recentCwd = {},     -- most-recent-first list
    recentModel = {},   -- { [agentId] = string }
    hyprland = false,   -- hyprctl available
    error = "",
  }
end

function M.migrate(value)
  if type(value) ~= "table" then
    return M.emptyStatus()
  end
  if value.schema ~= M.SCHEMA then
    local fresh = M.emptyStatus()
    for k, v in pairs(value) do
      if fresh[k] ~= nil then
        fresh[k] = v
      end
    end
    return fresh
  end
  return value
end

return M
