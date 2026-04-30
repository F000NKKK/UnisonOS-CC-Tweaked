-- gps-host: every stationary computer auto-broadcasts its own position
-- on the default GPS channel, so turtles and pocket computers in range
-- can resolve their coordinates the standard way.
--
-- Coordinate sources, in order:
--   1) /unison/state/gps-host.json      (saved manually with the
--                                        gps-tower shell command)
--   2) an existing GPS network          (gps.locate() — useful when
--                                        bootstrapping a new tower from
--                                        an existing one)
--
-- Skipped on turtles and pocket computers (they shouldn't be towers).

local log     = unison.kernel.log
local fsLib   = unison.lib.fs
local lib_gps = unison.lib.gps

local STATE_FILE = "/unison/state/gps-host.json"

local M = {}

local function isHostable()
    if turtle then return false, "turtle" end
    if pocket then return false, "pocket" end
    if not gps then return false, "no gps API" end
    return true
end

local function readSaved()
    local t = fsLib.readJson(STATE_FILE)
    if type(t) ~= "table" then return nil end
    if not (t.x and t.y and t.z) then return nil end
    return { x = tonumber(t.x), y = tonumber(t.y), z = tonumber(t.z),
             source = t.source or "manual" }
end

local function saveCoords(p) fsLib.writeJson(STATE_FILE, p) end

local function discoverFromNetwork()
    -- 1s timeout; lib.gps caches no-fix so we don't burn this on every retry
    local x, y, z = lib_gps.locate("self", { timeout = 1 })
    if not x then return nil end
    return { x = x, y = y, z = z, source = "network" }
end

local function hostLoop(coords)
    log.info("gps-host", string.format("hosting at %d,%d,%d (%s)",
        coords.x, coords.y, coords.z, coords.source or "manual"))
    -- gps.host() blocks forever broadcasting on the default GPS channel.
    -- It opens any wireless modem it can find.
    local ok, err = pcall(gps.host, coords.x, coords.y, coords.z)
    if not ok then log.warn("gps-host", "stopped: " .. tostring(err)) end
end

function M.run()
    local hostable, why = isHostable()
    if not hostable then
        log.info("gps-host", "skipping (" .. why .. ")")
        return
    end

    while true do
        local coords = readSaved()
        if not coords then
            coords = discoverFromNetwork()
            if coords then
                saveCoords(coords)
                log.info("gps-host", "auto-saved coords from network")
            end
        end
        if coords then
            hostLoop(coords)
            -- gps.host returned (modem error?). Wait then retry.
            sleep(15)
        else
            log.info("gps-host", "no coords known yet — set with 'gps-tower <x> <y> <z>'")
            sleep(60)
        end
    end
end

return M
