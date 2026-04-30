local M = {
    desc = "Get a GPS fix (local or HTTP). Short alias for gpsnet locate.",
    usage = "gps [target]    target = self (default), <id>, <name>",
}

local gpsLib = dofile("/unison/lib/gps.lua")

function M.run(ctx, args)
    local target = args[1] or "self"
    local x, y, z, src = gpsLib.locate(target)
    if not x then
        printError("gps: " .. tostring(y or src or "no fix"))
        return
    end
    print(string.format("%s: %d,%d,%d (%s)", tostring(target), x, y, z, tostring(src or "http")))
end

return M
