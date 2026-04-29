local M = {
    desc = "List devices registered with the VPS message bus",
    usage = "devices",
}

local function fmtAge(epoch)
    if not epoch then return "-" end
    local s = math.floor((os.epoch("utc") - epoch) / 1000)
    if s < 60 then return s .. "s" end
    if s < 3600 then return math.floor(s / 60) .. "m" end
    return math.floor(s / 3600) .. "h"
end

function M.run(ctx, args)
    local client = unison.rpc or dofile("/unison/rpc/client.lua")
    local list, err = client.devices()
    if not list then printError("rpc: " .. tostring(err)); return end
    print(string.format("%-12s %-10s %-8s %-7s %s", "ID", "ROLE", "VER", "SEEN", "NAME"))
    local ids = {}
    for id in pairs(list) do ids[#ids + 1] = id end
    table.sort(ids)
    if #ids == 0 then print("  (no devices registered)") end
    for _, id in ipairs(ids) do
        local d = list[id]
        print(string.format("%-12s %-10s %-8s %-7s %s",
            id:sub(1, 12),
            tostring(d.role or "-"),
            tostring(d.version or "-"),
            fmtAge(d.last_seen),
            tostring(d.name or "-")))
    end
end

return M
