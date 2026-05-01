local M = {
    desc = "Set / show this computer's GPS host coordinates",
    usage = "gps-tower <x> <y> <z>   |   gps-tower show   |   gps-tower clear",
}

local fsLib = unison.lib.fs
local STATE_FILE   = "/unison/state/gps-host.json"
local GPSNET_STATE = "/unison/state/gpsnet.lua"

-- Sync coords into gpsnet state so the bus heartbeat publishes the same
-- position as vanilla CC GPS broadcasts. Without this, gpsnet stays in
-- "auto" mode and tries lib.gps.locate(), which fails on a tower (a tower
-- can't triangulate itself).
local function syncToGpsnet(coords)
    local cur = fsLib.readLua(GPSNET_STATE)
    if type(cur) ~= "table" then cur = {} end
    cur.mode = "host"
    cur.host = { x = coords.x, y = coords.y, z = coords.z }
    fsLib.writeLua(GPSNET_STATE, cur)
end

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
        if fs.exists(GPSNET_STATE) then fs.delete(GPSNET_STATE) end
        print("cleared gps-host + gpsnet state. restart gps-host service.")
        return
    end
    local x, y, z = tonumber(args[1]), tonumber(args[2]), tonumber(args[3])
    if not (x and y and z) then printError("usage: " .. M.usage); return end
    fsLib.writeJson(STATE_FILE, { x = x, y = y, z = z, source = "manual" })
    syncToGpsnet({ x = x, y = y, z = z })
    print(string.format("saved %d,%d,%d (vanilla GPS + gpsnet host).", x, y, z))
    print("restart gps-host so it picks up the new coords:")
    print("  service restart gps-host")
end

return M
