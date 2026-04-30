local ipc = dofile("/unison/kernel/ipc.lua")
local log = dofile("/unison/kernel/log.lua")

local M = {}

local processes = {}
local nextPid = 1
local currentPid = nil

local function newPid()
    local p = nextPid
    nextPid = nextPid + 1
    return p
end

-- Priority is a `nice`-style integer in [-20, 19]: lower value = higher
-- priority. Default 0. Lower values are dispatched first when an event
-- needs to be delivered to multiple coroutines (so a high-priority shell
-- gets to react to a key-press before a background indexer does).
local DEFAULT_PRIO = 0

function M.spawn(fn, name, opts)
    opts = opts or {}
    local pid = newPid()
    local proc = {
        pid = pid,
        name = name or ("proc-" .. pid),
        co = coroutine.create(fn),
        status = "ready",
        filter = nil,
        started = os.epoch("utc"),
        priority = math.max(-20, math.min(19, tonumber(opts.priority) or DEFAULT_PRIO)),
        cpu_time = 0,        -- accumulated wall-time spent inside resume()
        resumes = 0,
        group = opts.group or "user",
    }
    processes[pid] = proc
    ipc.register(pid)
    log.debug("kernel", "spawn pid=" .. pid .. " name=" .. proc.name ..
        " prio=" .. proc.priority .. " group=" .. proc.group)
    return pid
end

function M.kill(pid)
    local p = processes[pid]
    if not p then return false end
    p.status = "dead"
    processes[pid] = nil
    ipc.unregister(pid)
    log.debug("kernel", "kill pid=" .. pid)
    return true
end

function M.list()
    local out = {}
    for pid, p in pairs(processes) do
        out[#out + 1] = {
            pid = pid,
            name = p.name,
            status = p.status,
            started = p.started,
            priority = p.priority,
            cpu_time = p.cpu_time,
            resumes = p.resumes,
            group = p.group,
        }
    end
    table.sort(out, function(a, b) return a.pid < b.pid end)
    return out
end

function M.get(pid) return processes[pid] end
function M.current() return currentPid end
function M.exists(pid) return processes[pid] ~= nil end

function M.setPriority(pid, value)
    local p = processes[pid]
    if not p then return false, "no such pid" end
    p.priority = math.max(-20, math.min(19, tonumber(value) or 0))
    return true
end

function M.nice(pid, delta)
    local p = processes[pid]
    if not p then return false, "no such pid" end
    return M.setPriority(pid, p.priority + (tonumber(delta) or 0))
end

local function resume(p, ev)
    if p.filter and ev[1] ~= p.filter and ev[1] ~= "terminate" then
        return
    end
    currentPid = p.pid
    p.status = "running"
    p.resumes = p.resumes + 1
    local t0 = os.clock()
    local ok, filterOrErr = coroutine.resume(p.co, table.unpack(ev))
    p.cpu_time = p.cpu_time + (os.clock() - t0)
    currentPid = nil
    if not ok then
        log.error("kernel", "pid=" .. p.pid .. " (" .. p.name .. ") crashed: " .. tostring(filterOrErr))
        p.status = "dead"
        processes[p.pid] = nil
        ipc.unregister(p.pid)
        return
    end
    if coroutine.status(p.co) == "dead" then
        log.debug("kernel", "pid=" .. p.pid .. " exited")
        processes[p.pid] = nil
        ipc.unregister(p.pid)
        return
    end
    p.filter = filterOrErr
    p.status = "blocked"
end

function M.run()
    local function nextEvent()
        return { os.pullEventRaw() }
    end

    local startup = { "unison_start" }
    for _, p in pairs(processes) do resume(p, startup) end

    while true do
        local hasAny = false
        for _ in pairs(processes) do hasAny = true; break end
        if not hasAny then
            log.info("kernel", "no processes left, scheduler exiting")
            return
        end
        local ev = nextEvent()
        if ev[1] == "terminate" then
            log.debug("kernel", "terminate delivered to user processes")
        end
        -- Snapshot, then sort by priority so high-prio coroutines see the
        -- event first — matters when several care about the same input.
        local snapshot = {}
        for pid, p in pairs(processes) do snapshot[#snapshot + 1] = p end
        table.sort(snapshot, function(a, b)
            if a.priority ~= b.priority then return a.priority < b.priority end
            return a.pid < b.pid
        end)
        for _, p in ipairs(snapshot) do
            if processes[p.pid] then resume(p, ev) end
        end
    end
end

return M
