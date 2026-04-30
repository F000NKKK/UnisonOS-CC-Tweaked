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
    end, name, { priority = opts.priority, group = opts.group })

    return proc
end

function Process:setPriority(v) return scheduler.setPriority(self.pid, v) end
function Process:nice(delta)    return scheduler.nice(self.pid, delta) end
function Process:info()         return scheduler.get(self.pid) end

----------------------------------------------------------------------
-- Cross-package exec — spawns an installed UPM package's main.lua as
-- a subprocess inside the same sandbox the shell would use.
----------------------------------------------------------------------

function M.exec(packageName, args, opts)
    deps()
    opts = opts or {}
    local appDir = "/unison/apps/" .. tostring(packageName)
    if not (fs.exists(appDir) and fs.isDir(appDir)) then
        return nil, "package not installed: " .. tostring(packageName)
    end

    local manifestFile = appDir .. "/manifest.lua"
    local entry = "main.lua"
    local permissions = { "all" }
    if fs.exists(manifestFile) then
        local fn = loadfile(manifestFile)
        if fn then
            local mok, m = pcall(fn)
            if mok and type(m) == "table" then
                entry = m.entry or entry
                if m.permissions then permissions = m.permissions end
            end
        end
    end

    local mainPath = appDir .. "/" .. entry
    if not fs.exists(mainPath) then
        return nil, "package entry missing: " .. mainPath
    end

    local sandbox = dofile("/unison/kernel/sandbox.lua")
    return M.spawn(function()
        local ok, err = sandbox.execFile(mainPath, permissions, table.unpack(args or {}))
        if not ok then error(err, 0) end
    end, packageName, {
        priority = opts.priority,
        group    = opts.group or "user",
    })
end

function M.findByName(name)
    deps()
    for _, info in ipairs(scheduler.list()) do
        if info.name == name then return info end
    end
    return nil
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
