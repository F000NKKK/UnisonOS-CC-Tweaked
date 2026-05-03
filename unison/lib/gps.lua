-- unison.lib.gps - position helpers over local gps API + Unison HTTP bus.
--
-- This module gives apps a unified way to resolve positions:
--   1) local hardware GPS (`gps.locate`) when available
--   2) HTTP bus device metrics (`/api/devices`) as fallback / remote lookup

local M = {}

local function iRound(n)
    n = tonumber(n)
    if not n then return nil end
    if n >= 0 then return math.floor(n + 0.5) end
    return math.ceil(n - 0.5)
end

local function getClient()
    if unison and unison.rpc and unison.rpc.devices then return unison.rpc end
    return dofile("/unison/rpc/client.lua")
end

-- Use rawget so a deserialised table with a hostile or cyclic
-- metatable can't trigger "loop in gettable" — the bus payload is
-- plain JSON and shouldn't have metatables, but we've seen it
-- happen in the wild and want to fail gracefully.
local function rg(t, k)
    if type(t) ~= "table" then return nil end
    return rawget(t, k)
end

local function normalizeDevices(raw)
    if type(raw) ~= "table" then return {} end
    local out = {}
    -- Hand-rolled iteration in pcall: even pairs() can throw if the
    -- payload was mangled into something with a hostile metatable.
    local ok = pcall(function()
        for k, d in pairs(raw) do
            if type(d) == "table" then
                local okId, id = pcall(function() return rg(d, "id") or k end)
                if okId and id ~= nil then
                    local okStr, sid = pcall(tostring, id)
                    if okStr then out[sid] = d end
                end
            end
        end
    end)
    if not ok then return {} end
    return out
end

local function extractPosition(device)
    local ok, result = pcall(function()
        local m = rg(device, "metrics")
        local p = rg(m, "position")
        if type(p) ~= "table" then return nil end

        local x = iRound(rg(p, "x") or rg(p, 1))
        local y = iRound(rg(p, "y") or rg(p, 2))
        local z = iRound(rg(p, "z") or rg(p, 3))
        if not (x and y and z) then return nil end

        return {
            x = x, y = y, z = z,
            source = rg(m, "position_source") or "http",
        }
    end)
    if not ok then return nil end
    return result
end

local function findDevice(devices, idOrName)
    if not idOrName then return nil end
    local key = tostring(idOrName)
    if devices[key] then return key, devices[key] end
    for id, d in pairs(devices) do
        if tostring(rg(d, "name") or "") == key then return id, d end
    end
    return nil
end

-- Cache the "local gps unavailable" decision so successive locate() calls
-- don't each waste a 1-2 second timeout when there are no GPS towers.
-- Cleared by M.resetGpsCache(); auto-expires after NO_GPS_TTL seconds.
local NO_GPS_TTL = 30
local noGpsUntil = 0

function M.resetGpsCache() noGpsUntil = 0 end

-- Locate a device:
--   locate() / locate("self") -> local gps first, then own HTTP metrics
--   locate("<id-or-name>")    -> HTTP metrics for that device
-- Returns: x, y, z, source or nil, err
function M.locate(target, opts)
    opts = opts or {}
    local isSelf = (not target) or target == "self"

    if isSelf and gps and not opts.http_only then
        local now = os.epoch and (os.epoch("utc") / 1000) or os.clock()
        -- opts.force = true bypasses the no-fix cache. Used by callers
        -- that need TWO fresh GPS reads back-to-back (e.g. nav.lib's
        -- facing probe — bus-cached coordinates wouldn't change between
        -- reads and the probe would report a bogus dx=0 dz=0).
        if opts.force or now >= noGpsUntil then
            -- pcall the vanilla CC API: in some worlds it panics with
            -- "loop in gettable" out of /rom/apis/gps.lua, presumably
            -- because _ENV.__index has been polluted by a buggy peer
            -- on the same modem channel. We fall back to bus locate.
            local ok, x, y, z = pcall(gps.locate, tonumber(opts.timeout) or 1)
            if ok and x then
                return iRound(x), iRound(y), iRound(z), "gps"
            end
            -- Mark gps as unavailable for a while so we stop blocking.
            noGpsUntil = now + NO_GPS_TTL
        end
    end

    local client = getClient()
    local okDev, devicesRaw, err = pcall(client.devices)
    if not okDev then return nil, "devices: " .. tostring(devicesRaw) end
    if not devicesRaw then return nil, "devices: " .. tostring(err) end

    local okN, devices = pcall(normalizeDevices, devicesRaw)
    if not okN then return nil, "devices: " .. tostring(devices) end

    local id, dev
    if isSelf then
        id = tostring(os.getComputerID())
        dev = devices[id]
    else
        local okF, fid, fdev = pcall(findDevice, devices, target)
        if not okF then return nil, "devices: " .. tostring(fid) end
        id, dev = fid, fdev
    end
    if not dev then return nil, "device not found: " .. tostring(target or "self") end

    local okP, pos = pcall(extractPosition, dev)
    if not okP then return nil, "metrics: " .. tostring(pos) end
    if not pos then return nil, "device has no position metrics: " .. tostring(id) end
    return pos.x, pos.y, pos.z, pos.source
end

-- List known devices with position metrics.
function M.devices(opts)
    opts = opts or {}
    local includeNoPos = opts.include_without_position == true
    local client = getClient()
    local okDev, devicesRaw, err = pcall(client.devices)
    if not okDev then return nil, "devices: " .. tostring(devicesRaw) end
    if not devicesRaw then return nil, "devices: " .. tostring(err) end
    local okN, devices = pcall(normalizeDevices, devicesRaw)
    if not okN then return nil, "devices: " .. tostring(devices) end

    local out = {}
    for id, d in pairs(devices) do
        local okP, pos = pcall(extractPosition, d)
        if okP and (pos or includeNoPos) then
            out[#out + 1] = {
                id = tostring(id),
                name = rg(d, "name"),
                role = rg(d, "role"),
                version = rg(d, "version"),
                last_seen = rg(d, "last_seen"),
                x = pos and pos.x or nil,
                y = pos and pos.y or nil,
                z = pos and pos.z or nil,
                source = pos and pos.source or nil,
            }
        end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

function M.distance(a, b)
    if not (a and b and a.x and a.y and a.z and b.x and b.y and b.z) then
        return nil, "distance requires {x,y,z} for both points"
    end
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

return M
