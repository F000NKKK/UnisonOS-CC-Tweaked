-- unison.lib.home — per-device home point (world-anchored coordinates).
--
-- The "home" of a turtle (or any node) is the world-space GPS point it
-- should return to when idle, on abort, or when fuel/inventory hits a
-- limit. mine, pilot and the dispatcher all read it through this
-- module so home configuration is a single source of truth.
--
-- Persisted at /unison/state/home.json:
--   { x = 123, y = 64, z = -45,    -- world coords (integers)
--     facing = 0,                   -- optional: 0=+x 1=+z 2=-x 3=-z
--     set_at = <epoch_ms>,
--     set_by = "<who>",             -- "shell" | "rpc:<id>" | "auto"
--     label  = "<freeform>" }       -- optional: "base alpha"
--
-- "auto" means the home was inferred (e.g. snapshot of GPS at first
-- boot). User-set entries beat auto entries when both exist on a fresh
-- read; we never silently overwrite a user-set home with an auto one.

local M = {}

local STATE_FILE = "/unison/state/home.json"

local function lib() return unison and unison.lib end

local function readRaw()
    local L = lib()
    if L and L.fs and L.fs.readJson then return L.fs.readJson(STATE_FILE) end
    if not fs.exists(STATE_FILE) then return nil end
    local h = fs.open(STATE_FILE, "r"); if not h then return nil end
    local s = h.readAll(); h.close()
    local ok, t = pcall(textutils.unserializeJSON, s)
    if not ok then return nil end
    return t
end

local function writeRaw(data)
    local L = lib()
    if L and L.fs and L.fs.writeJson then return L.fs.writeJson(STATE_FILE, data) end
    if not fs.exists("/unison/state") then fs.makeDir("/unison/state") end
    local h = fs.open(STATE_FILE, "w"); if not h then return false end
    h.write(textutils.serializeJSON(data)); h.close()
    return true
end

local function iRound(n)
    n = tonumber(n) or 0
    if n >= 0 then return math.floor(n + 0.5) end
    return math.ceil(n - 0.5)
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

-- Returns the home record (table) or nil if none is set.
function M.get()
    local t = readRaw()
    if type(t) ~= "table" then return nil end
    if not (tonumber(t.x) and tonumber(t.y) and tonumber(t.z)) then return nil end
    return t
end

-- Convenience: just the {x,y,z} (world coords) or nil. Caller can
-- use this directly with goHome / atlas / pathfinder.
function M.position()
    local h = M.get(); if not h then return nil end
    return { x = h.x, y = h.y, z = h.z }
end

-- Did the user explicitly set this home (vs an auto-inferred one)?
function M.isExplicit()
    local h = M.get(); if not h then return false end
    return h.set_by ~= nil and h.set_by ~= "auto"
end

-- Set home from a {x,y,z[,facing]} table. opts = { by, label, force }.
-- Refuses to overwrite an explicit home with an auto entry unless
-- opts.force = true.
function M.set(coord, opts)
    if type(coord) ~= "table" then return false, "coord required" end
    local x = tonumber(coord.x); local y = tonumber(coord.y); local z = tonumber(coord.z)
    if not (x and y and z) then return false, "x/y/z must be numbers" end

    opts = opts or {}
    local by = opts.by or "shell"

    if by == "auto" and not opts.force then
        local current = M.get()
        if current and current.set_by and current.set_by ~= "auto" then
            return false, "explicit home already set"
        end
    end

    local rec = {
        x = iRound(x), y = iRound(y), z = iRound(z),
        facing = tonumber(coord.facing),
        set_at = os.epoch and os.epoch("utc") or 0,
        set_by = by,
        label  = opts.label,
    }
    local ok = writeRaw(rec)
    if not ok then return false, "write failed" end
    return rec
end

-- Set home from the device's current GPS fix. Returns the new record
-- or nil, err. Useful for shell `home here` and the auto-init path.
function M.setFromGps(opts)
    local L = lib()
    if not (L and L.gps and L.gps.locate) then return nil, "gps lib unavailable" end
    local x, y, z, src = L.gps.locate("self", { timeout = 2 })
    if not x then return nil, "no gps fix" end
    if src ~= "gps" then return nil, "gps source: " .. tostring(src) end
    return M.set({ x = x, y = y, z = z }, opts)
end

function M.clear()
    if fs.exists(STATE_FILE) then fs.delete(STATE_FILE) end
    return true
end

return M
