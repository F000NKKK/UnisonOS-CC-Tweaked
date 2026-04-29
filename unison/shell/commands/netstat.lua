local M = {
    desc = "Show local network status (modems, channel, neighbors)",
    usage = "netstat",
}

function M.run(ctx, args)
    local transport = dofile("/unison/net/transport.lua")
    local router = dofile("/unison/net/router.lua")
    local auth = dofile("/unison/net/auth.lua")

    print("transport: " .. (transport.isStarted() and "up" or "down"))
    print("channel:   " .. transport.channel())
    print("modems:")
    local mlist = transport.modems()
    if #mlist == 0 then print("  (none)") end
    for _, m in ipairs(mlist) do
        print("  " .. m.name .. " (" .. m.kind .. ")")
    end
    print("enrolled:  " .. (auth.hasOwnKey() and "yes" or "no"))
    print("")
    print("neighbors (last seen via modem):")
    local n = router.neighbors()
    local empty = true
    for id, info in pairs(n) do
        empty = false
        local age = math.floor((os.epoch("utc") - info.last_seen) / 1000)
        print(string.format("  %-12s via %s, dist=%s, %ds ago",
            id:sub(1, 12), tostring(info.modem), tostring(info.distance or "?"), age))
    end
    if empty then print("  (none)") end
end

return M
