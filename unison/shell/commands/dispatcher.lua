-- `dispatcher` — inspect the local dispatcher daemon (master only).

local M = {
    desc  = "Inspect / enable / disable the local dispatcher daemon",
    usage = "dispatcher [status|workers|queue|enable|disable]",
}

local STATE = "/unison/state/dispatcher-enabled.json"

local function io_() return unison and unison.stdio end
local function svc() return unison and unison.dispatcher end

local function readEnabled()
    if not fs.exists(STATE) then return nil end
    local h = fs.open(STATE, "r"); if not h then return nil end
    local s = h.readAll(); h.close()
    local ok, t = pcall(textutils.unserializeJSON, s)
    if not ok or type(t) ~= "table" then return nil end
    return t.enabled and true or false
end

local function writeEnabled(on)
    if not fs.exists("/unison/state") then fs.makeDir("/unison/state") end
    local h = fs.open(STATE, "w"); if not h then return false end
    h.write(textutils.serializeJSON({ enabled = on and true or false }))
    h.close(); return true
end

local function ageS(ms)
    if not ms or ms == 0 then return "?" end
    local now = os.epoch and os.epoch("utc") or 0
    return string.format("%ds", math.floor((now - ms) / 1000))
end

local function showStatus(io, snap)
    local nq, na, nw = 0, 0, 0
    for _ in pairs(snap.queue) do nq = nq + 1 end
    for _ in pairs(snap.assignments) do na = na + 1 end
    for _ in pairs(snap.workers) do nw = nw + 1 end
    io.print(string.format("queue=%d  assignments=%d  workers=%d", nq, na, nw))
end

local function showWorkers(io, snap)
    io.print(string.format("%-12s %-8s %-5s %-12s %s",
        "WORKER", "KIND", "IDLE", "POS", "SEEN"))
    for id, w in pairs(snap.workers) do
        local pos = w.position and string.format("%d,%d,%d",
            w.position.x or 0, w.position.y or 0, w.position.z or 0) or "—"
        io.print(string.format("%-12s %-8s %-5s %-12s %s",
            id:sub(1, 12),
            tostring(w.kind or "?"),
            w.idle and "yes" or "no",
            pos,
            ageS(w.last_seen)))
    end
end

local function showQueue(io, snap)
    io.print(string.format("%-12s %-12s %-12s %s", "ID", "NAME", "STATE", "ASSIGNED"))
    for id, s in pairs(snap.queue) do
        local name = (s.name or ""):sub(1, 12)
        local assigned = snap.assignments[id] or "—"
        io.print(string.format("%-12s %-12s %-12s %s",
            id:sub(1, 12), name, tostring(s.state), assigned))
    end
end

local function trySvcRestart(io)
    -- Restart the service so the new state file takes effect immediately
    -- without forcing the user to reboot. If the kernel service manager
    -- isn't available (e.g. early boot), fall back to a friendly hint.
    local sm = unison and unison.kernel and unison.kernel.services
    if sm and sm.restart then
        local ok, err = pcall(sm.restart, "dispatcher")
        if ok then io.print("dispatcher service restarted.")
        else io.print("(restart hint: 'service restart dispatcher' — " .. tostring(err) .. ")") end
    else
        io.print("hint: run 'service restart dispatcher' (or reboot) to apply.")
    end
end

function M.run(ctx, args)
    local io = io_(); if not io then printError("stdio unavailable"); return end
    local sub = args[1] or "status"

    if sub == "enable" then
        writeEnabled(true)
        io.print("dispatcher: enabled (state file written).")
        trySvcRestart(io)
        return
    end

    if sub == "disable" then
        writeEnabled(false)
        io.print("dispatcher: disabled (state file written).")
        trySvcRestart(io)
        return
    end

    -- Inspector subcommands need the running service.
    local d = svc()
    if not d then
        local en = readEnabled()
        if en == true then
            io.printError("dispatcher is enabled in state but service is not active. Try 'service restart dispatcher'.")
        elseif en == false then
            io.printError("dispatcher is disabled (override). Run 'dispatcher enable' to start it.")
        else
            io.printError("dispatcher service is not running on this node.")
            io.print("Run 'dispatcher enable' to turn it on (or set config.dispatcher = true).")
        end
        return
    end

    local snap = d.snapshot()
    if sub == "status"  then return showStatus(io, snap) end
    if sub == "workers" then return showWorkers(io, snap) end
    if sub == "queue"   then return showQueue(io, snap) end

    io.printError("unknown subcommand: " .. tostring(sub))
    io.print("usage: " .. M.usage)
end

return M
