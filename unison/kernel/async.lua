-- unison.kernel.async — futures + parallel / race over the cooperative
-- scheduler. Each "future" is a process whose result is captured when its
-- function returns; await blocks the current coroutine until that happens.

local process_mod
local function deps()
    process_mod = process_mod
        or (unison and unison.kernel and unison.kernel.process)
        or dofile("/unison/kernel/process.lua")
end

local M = {}

----------------------------------------------------------------------
-- Single future
----------------------------------------------------------------------

local Future = {}
Future.__index = Future

function Future:done()    return self._proc._done end
function Future:cancel()  return self._proc:kill() end
function Future:result()  return self._proc:wait() end

function Future:await(timeout)
    return self._proc:wait(timeout)
end

function M.future(fn, name)
    deps()
    local proc = process_mod.spawn(fn, name or "future")
    return setmetatable({ _proc = proc }, Future)
end

----------------------------------------------------------------------
-- parallel: run all, wait all, return ordered results
----------------------------------------------------------------------

function M.parallel(fns, opts)
    deps()
    opts = opts or {}
    local procs, results, errors = {}, {}, {}
    for i, fn in ipairs(fns) do
        procs[i] = process_mod.spawn(fn, (opts.name or "par") .. ":" .. i)
    end
    for i, p in ipairs(procs) do
        local r, err = p:wait(opts.timeout)
        results[i] = r; errors[i] = err
    end
    return results, errors
end

----------------------------------------------------------------------
-- race: return as soon as the FIRST one finishes
----------------------------------------------------------------------

function M.race(fns, opts)
    deps()
    opts = opts or {}
    local procs = {}
    for i, fn in ipairs(fns) do
        procs[i] = process_mod.spawn(fn, (opts.name or "race") .. ":" .. i)
    end

    local deadline = opts.timeout and (os.clock() + opts.timeout) or nil
    while true do
        for i, p in ipairs(procs) do
            if p._done then
                -- cancel the rest
                for j, q in ipairs(procs) do
                    if j ~= i and not q._done then q:kill() end
                end
                return i, p:result()
            end
        end
        if deadline then
            local left = deadline - os.clock()
            if left <= 0 then
                for _, p in ipairs(procs) do if not p._done then p:kill() end end
                return nil, "timeout"
            end
            local t = os.startTimer(left)
            while true do
                local ev, a = os.pullEvent()
                if ev == "unison_process_done" then break end
                if ev == "timer" and a == t then break end
            end
        else
            os.pullEvent("unison_process_done")
        end
    end
end

----------------------------------------------------------------------
-- map: run fn over a list in parallel
----------------------------------------------------------------------

function M.map(items, fn, opts)
    local fns = {}
    for i, item in ipairs(items) do
        local cap = item; local idx = i
        fns[i] = function() return fn(cap, idx) end
    end
    return M.parallel(fns, opts)
end

----------------------------------------------------------------------
-- delay / sleep / interval helpers (cooperative)
----------------------------------------------------------------------

function M.delay(seconds, fn)
    deps()
    return process_mod.spawn(function()
        sleep(seconds)
        return fn()
    end, "delay")
end

function M.interval(seconds, fn)
    deps()
    return process_mod.spawn(function()
        while true do
            local ok, err = pcall(fn)
            if not ok then
                local log = unison and unison.kernel and unison.kernel.log
                if log then log.warn("async", "interval error: " .. tostring(err)) end
            end
            sleep(seconds)
        end
    end, "interval")
end

return M
