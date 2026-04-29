local M = {
    desc = "List enrolled nodes (master only)",
    usage = "nodes",
}

local function fmtAge(epoch)
    if not epoch then return "-" end
    local s = math.floor((os.epoch("utc") - epoch) / 1000)
    if s < 60 then return s .. "s" end
    if s < 3600 then return math.floor(s / 60) .. "m" end
    return math.floor(s / 3600) .. "h"
end

function M.run(ctx, args)
    if unison.role ~= "master" then
        printError("nodes is only available on master node")
        return
    end
    local router = dofile("/unison/net/router.lua")
    router.markStale(15000)
    local known = router.knownNodes()
    print(string.format("%-12s %-10s %-7s %-7s %s", "ID", "ROLE", "STATUS", "SEEN", "ENROLLED"))
    local ids = {}
    for id in pairs(known) do ids[#ids + 1] = id end
    table.sort(ids)
    if #ids == 0 then print("  (no enrolled nodes)") end
    for _, id in ipairs(ids) do
        local n = known[id]
        local role = tostring(n.role or "-")
        local status = n.revoked and "REVOKED" or (n.status or "?")
        local seen = fmtAge(n.last_seen)
        local enr = fmtAge(n.enrolled_at)
        print(string.format("%-12s %-10s %-7s %-7s %s", id:sub(1, 12), role, status, seen, enr))
    end
end

return M
