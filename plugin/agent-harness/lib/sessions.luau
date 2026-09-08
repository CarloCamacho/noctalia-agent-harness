--!nonstrict
-- Per-project session discovery.
--
-- Pi stores sessions as ~/.pi/agent/sessions/--<encoded-cwd>--/<ts>_<uuid>.jsonl
-- (verified live; see docs/phase0-findings.md). Hermes has no per-cwd store yet, so
-- `newest` returns nil for it and the panel falls back to the adapter's own --continue.

local M = {}

function M.dir(adapter, cwd)
  if adapter == nil or adapter.sessionDir == nil then
    return nil
  end
  return adapter.sessionDir(noctalia.getenv("HOME") or "", cwd)
end

-- Newest session file in the adapter's store for this cwd, or nil.
function M.newest(adapter, cwd)
  local dir = M.dir(adapter, cwd)
  if type(dir) ~= "string" or dir == "" then
    return nil
  end
  local listing = noctalia.listDir(dir)
  if type(listing) ~= "table" then
    return nil
  end
  local best = nil
  for _, name in ipairs(listing) do
    if name:sub(-6) == ".jsonl" then
      local path = dir .. "/" .. name
      local info = noctalia.fileInfo(path)
      if info ~= nil and not info.isDir then
        local stamp = tonumber(info.mtime) or 0
        if best == nil or stamp > best.mtime then
          best = {
            file = name,
            path = path,
            mtime = stamp,
            id = name:match("_(.+)%.jsonl$") or name,
          }
        end
      end
    end
  end
  return best
end

function M.describe(session)
  if session == nil then
    return nil
  end
  return session.id
end

return M
