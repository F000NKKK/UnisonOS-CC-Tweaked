-- unison.lib.busy — cooperative busy-job registry.
--
-- Long-running user jobs (mining, farming, scanning, patrolling) call
-- markBusy(name) on entry and clearBusy(token) on exit. System services
-- like os-updater consult busyJobs() before disruptive actions
-- (reboots, file overwrites) and defer until every outstanding token
-- is cleared.
--
-- Multiple concurrent jobs stack: the device is busy as long as at
-- least one token is outstanding.
--
-- Lives in lib/ rather than kernel/ because the busy concept is purely
-- application-side coordination — the kernel doesn't act on it. The
-- previous home (kernel/process.markBusy) still works as a thin alias
-- for backward compatibility.

local M = {}

local _jobs = {}
local _seq  = 0

function M.markBusy(name, meta)
    _seq = _seq + 1
    local token = _seq
    _jobs[token] = {
        token = token,
        name  = tostring(name or "job"),
        since = os.epoch("utc"),
        meta  = meta,
    }
    return token
end

function M.clearBusy(token)
    if token == nil then return end
    _jobs[token] = nil
end

function M.busyJobs()
    local out = {}
    for _, j in pairs(_jobs) do out[#out + 1] = j end
    return out
end

function M.isBusy() return next(_jobs) ~= nil end

-- Convenience wrapper: run fn while marking the device busy. Clears
-- the token even if fn errors.
function M.with(name, fn)
    local tok = M.markBusy(name)
    local ok, err = pcall(fn)
    M.clearBusy(tok)
    if not ok then error(err, 0) end
end

return M
