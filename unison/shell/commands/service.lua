local M = {
    desc = "Manage UnisonOS services (list/status/start/stop/restart)",
    usage = "service <list|status|start|stop|restart> [name]",
}

local function svc()
    return unison.kernel.services
end

local function cmdList()
    local rows = svc().list()
    print(string.format("%-16s %-9s %-4s %-9s %s", "NAME", "STATE", "PID", "RESTARTS", "DESCRIPTION"))
    if #rows == 0 then print("  (no units)") end
    for _, r in ipairs(rows) do
        print(string.format("%-16s %-9s %-4s %-9d %s",
            r.name:sub(1, 16),
            r.status,
            tostring(r.pid or "-"),
            r.restarts or 0,
            (r.description or ""):sub(1, 40)))
    end
end

local function cmdStatus(name)
    if not name then printError("usage: service status <name>"); return end
    local s = svc().status(name)
    print(name)
    print("  state:    " .. tostring(s.status or "?"))
    print("  pid:      " .. tostring(s.pid or "-"))
    print("  restarts: " .. tostring(s.restarts or 0))
    if s.last_error then print("  error:    " .. tostring(s.last_error)) end
    if s.started_at then
        local age = math.floor((os.epoch("utc") - s.started_at) / 1000)
        print("  uptime:   " .. age .. "s")
    end
end

local function cmdStart(name)
    if not name then printError("usage: service start <name>"); return end
    local ok, err = svc().start(name)
    if ok then print("started " .. name) else printError("error: " .. tostring(err)) end
end

local function cmdStop(name)
    if not name then printError("usage: service stop <name>"); return end
    svc().stop(name)
    print("stopped " .. name)
end

local function cmdRestart(name)
    if not name then printError("usage: service restart <name>"); return end
    local ok, err = svc().restart(name)
    if ok then print("restarted " .. name) else printError("error: " .. tostring(err)) end
end

function M.run(ctx, args)
    local sub = args[1] or "list"
    local name = args[2]
    if     sub == "list"    then cmdList()
    elseif sub == "status"  then cmdStatus(name)
    elseif sub == "start"   then cmdStart(name)
    elseif sub == "stop"    then cmdStop(name)
    elseif sub == "restart" then cmdRestart(name)
    else printError("unknown subcommand: " .. sub); print("usage: " .. M.usage) end
end

return M
