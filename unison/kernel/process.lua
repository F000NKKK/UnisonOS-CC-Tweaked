-- unison.kernel.process — richer wrapper around the cooperative scheduler.
-- Each Process has: pid, name, kill(), wait(timeout?), status(), send(msg),
-- recv(timeout?), and a result captured when its main fn returns.
--
-- All processes are scheduler coroutines; this module is just a friendlier
-- handle around the existing kernel/scheduler.lua + kernel/ipc.lua.

local M = {}

local scheduler, ipc, log

local function deps()
    if scheduler then return end
    scheduler = unison and unison.kernel and unison.kernel.scheduler
                or dofile("/unison/kernel/scheduler.lua")
    ipc       = unison and unison.kernel and unison.kernel.ipc
                or dofile("/unison/kernel/ipc.lua")
    log       = unison and unison.kernel and unison.kernel.log
                or dofile("/unison/kernel/log.lua")
end

local Process = {}
Process.__index = Process

function Process:running()
    return scheduler.exists(self.pid) and not self._done
end

function Process:status()
    if self._done then return self._error and "failed" or "exited" end
    return scheduler.exists(self.pid) and "running" or "missing"
end

function Process:result()
    return self._result, self._error
end

function Process:kill()
    if self._done then return false end
    scheduler.kill(self.pid)
    self._done = true
    self._error = self._error or "killed"
    -- wake up anyone waiting on us
    os.queueEvent("unison_process_done", self.pid)
    return true
end

function Process:wait(timeout)
    if self._done then return self._result, self._error end
    local deadline = timeout and (os.clock() + timeout) or nil
    while not self._done do
        if deadline then
            local left = deadline - os.clock()
            if left <= 0 then return nil, "timeout" end
            local timer = os.startTimer(left)
            while true do
                local ev, a = os.pullEvent()
                if ev == "unison_process_done" and a == self.pid then break end
                if ev == "timer" and a == timer then return nil, "timeout" end
            end
        else
            while true do
                local ev, a = os.pullEvent("unison_process_done")
                if a == self.pid then break end
            end
        end
    end
    return self._result, self._error
end

function Process:send(msg)
    return ipc.send(self.pid, msg)
end

function Process:recv(timeout)
    return ipc.recv(self.pid, timeout)
end

----------------------------------------------------------------------
-- Spawn
----------------------------------------------------------------------

function M.spawn(fn, name, opts)
    deps()
    opts = opts or {}
    local proc = setmetatable({
        name = name or "proc",
        _done = false, _result = nil, _error = nil,
    }, Process)

    proc.pid = scheduler.spawn(function()
        local ok, ret = pcall(fn, proc, opts.args and table.unpack(opts.args) or nil)
        if ok then proc._result = ret
        else proc._error = ret; log.warn("process", "pid=" .. proc.pid .. " (" .. proc.name .. ") error: " .. tostring(ret)) end
        proc._done = true
        os.queueEvent("unison_process_done", proc.pid)
    end, name)

    return proc
end

function M.list()
    deps()
    return scheduler.list()
end

function M.byPid(pid)
    deps()
    if not scheduler.exists(pid) then return nil end
    return { pid = pid, name = "?" }   -- limited handle for foreign pids
end

return M
