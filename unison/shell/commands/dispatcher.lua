-- `dispatcher` — inspect the local dispatcher daemon (master only).

local M = {
    desc = "Inspect dispatcher state (queue, assignments, workers)",
    usage = "dispatcher [status|workers|queue]",
}

local function io_() return unison and unison.stdio end
local function svc() return unison and unison.dispatcher end

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

function M.run(ctx, args)
    local io = io_(); if not io then printError("stdio unavailable"); return end
    local d  = svc()
    if not d then io.printError("dispatcher service not running on this node"); return end

    local snap = d.snapshot()
    local sub = args[1] or "status"
    if sub == "status"  then return showStatus(io, snap) end
    if sub == "workers" then return showWorkers(io, snap) end
    if sub == "queue"   then return showQueue(io, snap) end

    io.printError("unknown subcommand: " .. tostring(sub))
    io.print("usage: " .. M.usage)
end

return M
