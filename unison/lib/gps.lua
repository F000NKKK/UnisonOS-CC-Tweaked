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

local function normalizeDevices(raw)
    if type(raw) ~= "table" then return {} end
    local out = {}
    for k, d in pairs(raw) do
        if type(d) == "table" then
            local id = d.id or k
            out[tostring(id)] = d
        end
    end
    return out
end

local function extractPosition(device)
    local m = device and device.metrics
    local p = m and m.position
    if type(p) ~= "table" then return nil end

    local x = iRound(p.x or p[1])
    local y = iRound(p.y or p[2])
    local z = iRound(p.z or p[3])
    if not (x and y and z) then return nil end

    return {
        x = x, y = y, z = z,
        source = m.position_source or "http",
    }
end

local function findDevice(devices, idOrName)
    if not idOrName then return nil end
    local key = tostring(idOrName)
    if devices[key] then return key, devices[key] end
    for id, d in pairs(devices) do
        if tostring(d.name or "") == key then return id, d end
    end
    return nil
end

-- Locate a device:
--   locate() / locate("self") -> local gps first, then own HTTP metrics
--   locate("<id-or-name>")    -> HTTP metrics for that device
-- Returns: x, y, z, source or nil, err
function M.locate(target, opts)
    opts = opts or {}
    local isSelf = (not target) or target == "self"

    if isSelf and gps and not opts.http_only then
        local x, y, z = gps.locate(tonumber(opts.timeout) or 2)
        if x then
            return iRound(x), iRound(y), iRound(z), "gps"
        end
    end

    local client = getClient()
    local devicesRaw, err = client.devices()
    if not devicesRaw then return nil, "devices: " .. tostring(err) end
    local devices = normalizeDevices(devicesRaw)

    local id, dev
    if isSelf then
        id = tostring(os.getComputerID())
        dev = devices[id]
    else
        id, dev = findDevice(devices, target)
    end
    if not dev then return nil, "device not found: " .. tostring(target or "self") end

    local pos = extractPosition(dev)
    if not pos then return nil, "device has no position metrics: " .. tostring(id) end
    return pos.x, pos.y, pos.z, pos.source
end

-- List known devices with position metrics.
function M.devices(opts)
    opts = opts or {}
    local includeNoPos = opts.include_without_position == true
    local client = getClient()
    local devicesRaw, err = client.devices()
    if not devicesRaw then return nil, "devices: " .. tostring(err) end
    local devices = normalizeDevices(devicesRaw)

    local out = {}
    for id, d in pairs(devices) do
        local pos = extractPosition(d)
        if pos or includeNoPos then
            out[#out + 1] = {
                id = tostring(id),
                name = d.name,
                role = d.role,
                version = d.version,
                last_seen = d.last_seen,
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
