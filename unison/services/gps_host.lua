-- gps-host: full auto-discovery and broadcast.
--
-- Behaviour, in order:
--   1) Open every attached wireless modem (so gps.locate works without
--      any manual `rednet.open <side>`).
--   2) Migrate legacy gps-host.json into gpsnet state if missing, so the
--      bus heartbeat matches the vanilla GPS broadcast.
--   3) If saved coords exist, host immediately.
--   4) Otherwise poll gps.locate() with backoff (5..60s) until 4+ towers
--      can triangulate this device, save the fix, host.
--   5) React to peripheral_attach to retry locate() instantly when a new
--      modem is hot-plugged.
--   6) gps.host blocks forever; if it ever returns (modem error), the
--      outer loop re-enters and resumes hosting.
--
-- Skipped on turtles and pocket computers — they shouldn't be towers.

local log     = unison.kernel.log
local fsLib   = unison.lib.fs
local lib_gps = unison.lib.gps

local STATE_FILE   = "/unison/state/gps-host.json"
local GPSNET_STATE = "/unison/state/gpsnet.lua"

local M = {}

local function isHostable()
    if turtle then return false, "turtle" end
    if pocket then return false, "pocket" end
    if not gps then return false, "no gps API" end
    return true
end

-- Open every attached wireless modem on rednet so gps.locate / rednet
-- traffic works out of the box. CC's gps.locate scans wrapped modems
-- directly so it doesn't strictly need rednet.open, but apps using
-- rednet.* do — and opening here is harmless if already open.
local function openWirelessModems()
    if not (peripheral and rednet) then return 0 end
    local n = 0
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then
            local ok, wireless = pcall(peripheral.call, name, "isWireless")
            if ok and wireless and not rednet.isOpen(name) then
                if pcall(rednet.open, name) then n = n + 1 end
            end
        end
    end
    return n
end

local function readSaved()
    local t = fsLib.readJson(STATE_FILE)
    if type(t) ~= "table" then return nil end
    if not (t.x and t.y and t.z) then return nil end
    return { x = tonumber(t.x), y = tonumber(t.y), z = tonumber(t.z),
             source = t.source or "manual" }
end

local function syncToGpsnet(p)
    local cur = fsLib.readLua(GPSNET_STATE)
    if type(cur) ~= "table" then cur = {} end
    cur.mode = "host"
    cur.host = { x = p.x, y = p.y, z = p.z }
    cur.updated_at = os.epoch("utc")
    fsLib.writeLua(GPSNET_STATE, cur)
end

local function saveCoords(p)
    fsLib.writeJson(STATE_FILE, p)
    syncToGpsnet(p)
end

local function tryLocate(timeout)
    -- Reset the no-fix cache so we don't get stuck for NO_GPS_TTL seconds
    -- after another tower comes online.
    if lib_gps.resetGpsCache then lib_gps.resetGpsCache() end
    local x, y, z, src = lib_gps.locate("self", { timeout = timeout or 1 })
    if not x or src ~= "gps" then return nil end
    return { x = x, y = y, z = z, source = "network" }
end

-- Wait until either a peripheral attach event arrives or `secs` pass.
-- Returns "modem" if a wireless modem appeared, else "timeout".
local function waitForRetry(secs)
    local deadline = os.startTimer(secs)
    while true do
        local ev, p = os.pullEvent()
        if ev == "timer" and p == deadline then return "timeout" end
        if ev == "peripheral" then
            -- Hot-plug: open it if it's a wireless modem and bail early.
            if peripheral.getType(p) == "modem" then
                local ok, wireless = pcall(peripheral.call, p, "isWireless")
                if ok and wireless then
                    if rednet and not rednet.isOpen(p) then pcall(rednet.open, p) end
                    return "modem"
                end
            end
        end
    end
end

local function discoverLoop()
    local backoff = 5
    while true do
        local coords = tryLocate(1)
        if coords then
            saveCoords(coords)
            log.info("gps-host", string.format(
                "auto-detected %d,%d,%d via network", coords.x, coords.y, coords.z))
            return coords
        end
        log.debug("gps-host", "no fix yet — retry in " .. backoff .. "s")
        local how = waitForRetry(backoff)
        if how == "modem" then backoff = 5 else backoff = math.min(backoff * 2, 60) end
    end
end

function M.run()
    local hostable, why = isHostable()
    if not hostable then
        log.info("gps-host", "skipping (" .. why .. ")")
        return
    end

    local opened = openWirelessModems()
    if opened > 0 then log.info("gps-host", "opened " .. opened .. " wireless modem(s)") end

    while true do
        local coords = readSaved()
        if coords then
            -- Make sure gpsnet state matches even on legacy installs that
            -- set gps-host.json before we started syncing.
            syncToGpsnet(coords)
        else
            coords = discoverLoop()
        end

        log.info("gps-host", string.format("hosting at %d,%d,%d (%s)",
            coords.x, coords.y, coords.z, coords.source or "manual"))
        local ok, err = pcall(gps.host, coords.x, coords.y, coords.z)
        if not ok then log.warn("gps-host", "stopped: " .. tostring(err)) end
        sleep(15)
    end
end

return M
