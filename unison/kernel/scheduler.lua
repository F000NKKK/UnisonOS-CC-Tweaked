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

function M.spawn(fn, name)
    local pid = newPid()
    local proc = {
        pid = pid,
        name = name or ("proc-" .. pid),
        co = coroutine.create(fn),
        status = "ready",
        filter = nil,
        started = os.epoch("utc"),
    }
    processes[pid] = proc
    ipc.register(pid)
    log.debug("kernel", "spawn pid=" .. pid .. " name=" .. proc.name)
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
        }
    end
    table.sort(out, function(a, b) return a.pid < b.pid end)
    return out
end

function M.current()
    return currentPid
end

function M.exists(pid)
    return processes[pid] ~= nil
end

local function resume(p, ev)
    if p.filter and ev[1] ~= p.filter and ev[1] ~= "terminate" then
        return
    end
    currentPid = p.pid
    p.status = "running"
    local ok, filterOrErr = coroutine.resume(p.co, table.unpack(ev))
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
            log.warn("kernel", "terminate received")
        end
        local snapshot = {}
        for pid, p in pairs(processes) do snapshot[#snapshot + 1] = p end
        for _, p in ipairs(snapshot) do
            if processes[p.pid] then resume(p, ev) end
        end
        if ev[1] == "terminate" then return end
    end
end

return M
