local M = {
    desc = "Set / show this computer's GPS host coordinates",
    usage = "gps-tower <x> <y> <z>   |   gps-tower show   |   gps-tower clear",
}

local fsLib = unison.lib.fs
local STATE_FILE = "/unison/state/gps-host.json"

local function show()
    local t = fsLib.readJson(STATE_FILE)
    if not t then print("(no coords saved)"); return end
    print(string.format("gps-host coords: %d, %d, %d  (source=%s)",
        t.x or 0, t.y or 0, t.z or 0, tostring(t.source or "manual")))
end

function M.run(ctx, args)
    local sub = args[1]
    if not sub or sub == "show" then return show() end
    if sub == "clear" then
        if fs.exists(STATE_FILE) then fs.delete(STATE_FILE) end
        print("cleared. restart 'gps-host' service to re-detect.")
        return
    end
    local x, y, z = tonumber(args[1]), tonumber(args[2]), tonumber(args[3])
    if not (x and y and z) then printError("usage: " .. M.usage); return end
    fsLib.writeJson(STATE_FILE, { x = x, y = y, z = z, source = "manual" })
    print(string.format("saved %d,%d,%d. restart the gps-host service to apply:", x, y, z))
    print("  service restart gps-host")
end

return M
