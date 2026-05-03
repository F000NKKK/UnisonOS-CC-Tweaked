-- unison.lib.nav — world-coordinate movement for turtles.
--
-- Built on top of CC's `turtle` global, `unison.lib.gps` and the
-- naive xyz traversal pattern: align facing → step forward (with
-- tunneling-through-obstacles) → repeat. The dispatcher uses this to
-- park a worker at a volume's corner before mine starts; mine itself
-- can use it for go-home flows that need precise world targeting.
--
-- The big trick is recovering the turtle's WORLD facing on demand.
-- CC tracks no compass heading, so we infer it by GPS-probing: read
-- pos, step forward (dig if blocked), read pos again, the delta tells
-- us which world axis "+forward" maps to.
--
-- Public surface:
--   nav.facing()     — returns 0/1/2/3 (0=+x, 1=+z, 2=-x, 3=-z) or nil
--   nav.position()   — world {x,y,z} from GPS, or nil
--   nav.faceAxis(axis) — axis = "+x"|"-x"|"+z"|"-z"; turn turtle in place
--   nav.goTo({x,y,z}, opts) — walk to target. opts:
--       dig          (true = tunnel through blocks; default true)
--       attack       (true = attack mobs in the way; default false —
--                     "no harm" rule from mine)
--       fuel_buffer  (don't move below this; default 0)
--   On success returns true, finalPos. On failure returns false, err.
--
-- Limitations: no pathfinding, just X then Z then Y axis-aligned
-- traversal. Fine for above-ground or open-tunnel parking; fails on
-- bedrock / lava / walls-with-windows. The caller can detect the
-- error and try an A*-routed path through the atlas instead.

local M = {}

local FACE_TO_DELTA = {
    [0] = { dx =  1, dz =  0 },
    [1] = { dx =  0, dz =  1 },
    [2] = { dx = -1, dz =  0 },
    [3] = { dx =  0, dz = -1 },
}

local function gpsPos()
    local L = unison and unison.lib
    if not (L and L.gps) then return nil end
    local x, y, z, src = L.gps.locate("self", { timeout = 1 })
    if not x then return nil end
    return { x = math.floor(x + 0.5),
             y = math.floor(y + 0.5),
             z = math.floor(z + 0.5),
             src = src }
end

-- Forced fresh fix from vanilla CC GPS, bypassing the no-fix cache.
-- The facing probe needs TWO reads that reflect actual movement; a
-- bus-cached coordinate (heartbeat-updated every 10 s) would lie about
-- the second one and produce dx=0 dz=0 for the probe.
local function gpsPosFresh()
    local L = unison and unison.lib
    if not (L and L.gps) then return nil end
    if L.gps.resetGpsCache then L.gps.resetGpsCache() end
    local x, y, z, src = L.gps.locate("self", { timeout = 2, force = true })
    if not x then return nil, "no gps fix" end
    if src ~= "gps" then
        return nil, "gps source is '" .. tostring(src) ..
            "', need vanilla CC GPS for the facing probe"
    end
    return { x = math.floor(x + 0.5),
             y = math.floor(y + 0.5),
             z = math.floor(z + 0.5),
             src = src }
end

M.position = gpsPos

----------------------------------------------------------------------
-- Facing detection (probe)
----------------------------------------------------------------------

local function tryStepForward(opts)
    -- One forward step. Tunnels through blocks if opts.dig (default).
    -- Refuses to attack mobs (entity in the way blocks the move and
    -- we report it; caller can retry / give up).
    local dig = (opts and opts.dig) ~= false
    if turtle.forward() then return true end
    if not dig then return false, "blocked" end
    if turtle.detect() then
        if not turtle.dig() then return false, "dig failed" end
        if turtle.forward() then return true end
        return false, "still blocked after dig"
    end
    -- detect=false but forward failed → likely an entity (mob / player).
    return false, "blocked by entity"
end

local function probeFacing(opts)
    local p1, e1 = gpsPosFresh()
    if not p1 then return nil, e1 or "no gps fix" end

    local ok, err = tryStepForward(opts)
    if not ok then
        -- Try a 180° spin and step the other way; restore on success.
        turtle.turnRight(); turtle.turnRight()
        ok, err = tryStepForward(opts)
        if not ok then
            turtle.turnRight(); turtle.turnRight()  -- restore facing
            return nil, "probe blocked both ways: " .. tostring(err)
        end
        local p2, e2 = gpsPosFresh()
        if not p2 then
            turtle.back(); turtle.turnRight(); turtle.turnRight()
            return nil, "no gps after probe: " .. tostring(e2)
        end
        local dx = p2.x - p1.x; local dz = p2.z - p1.z
        -- We stepped while facing the OPPOSITE of original; flip back.
        turtle.back()
        turtle.turnRight(); turtle.turnRight()
        if dx == 0 and dz == 0 then
            return nil, "ambiguous probe: gps reported same coords " ..
                "before/after a successful step (stale fix?)"
        end
        for f, d in pairs(FACE_TO_DELTA) do
            if d.dx == -dx and d.dz == -dz then return f end
        end
        return nil, "ambiguous probe (dx=" .. dx .. " dz=" .. dz .. ")"
    end

    local p2, e2 = gpsPosFresh()
    if not p2 then
        turtle.back(); return nil, "no gps after probe: " .. tostring(e2)
    end
    local dx = p2.x - p1.x; local dz = p2.z - p1.z
    turtle.back()
    if dx == 0 and dz == 0 then
        return nil, "ambiguous probe: gps reported same coords " ..
            "before/after a successful step (stale fix?)"
    end
    for f, d in pairs(FACE_TO_DELTA) do
        if d.dx == dx and d.dz == dz then return f end
    end
    return nil, "ambiguous probe (dx=" .. dx .. " dz=" .. dz .. ")"
end

local _cachedFacing = nil

function M.facing(opts)
    -- Cache last known facing across calls. Anyone who turns the
    -- turtle outside nav.faceAxis must call M.invalidateFacing().
    if _cachedFacing ~= nil then return _cachedFacing end
    local f, err = probeFacing(opts)
    if f then _cachedFacing = f end
    return f, err
end

function M.invalidateFacing() _cachedFacing = nil end

local function turnLeft()
    turtle.turnLeft()
    if _cachedFacing then _cachedFacing = (_cachedFacing + 3) % 4 end
end
local function turnRight()
    turtle.turnRight()
    if _cachedFacing then _cachedFacing = (_cachedFacing + 1) % 4 end
end

local AXIS_TO_FACING = { ["+x"] = 0, ["+z"] = 1, ["-x"] = 2, ["-z"] = 3 }

function M.faceAxis(axis, opts)
    local target = AXIS_TO_FACING[axis]
    if not target then return false, "bad axis: " .. tostring(axis) end
    local cur, err = M.facing(opts); if not cur then return false, err end
    local diff = (target - cur) % 4
    if diff == 0 then return true end
    if diff == 1 then turnRight()
    elseif diff == 2 then turnRight(); turnRight()
    elseif diff == 3 then turnLeft() end
    return true
end

----------------------------------------------------------------------
-- Movement helpers (one-step primitives + run loops)
----------------------------------------------------------------------

local function stepUp(opts)
    local dig = (opts and opts.dig) ~= false
    if turtle.up() then return true end
    if not dig then return false, "blocked up" end
    if turtle.detectUp() and turtle.digUp() and turtle.up() then return true end
    return false, "blocked up"
end

local function stepDown(opts)
    local dig = (opts and opts.dig) ~= false
    if turtle.down() then return true end
    if not dig then return false, "blocked down" end
    if turtle.detectDown() and turtle.digDown() and turtle.down() then return true end
    return false, "blocked down"
end

local function runForward(n, opts)
    for i = 1, n do
        local ok, err = tryStepForward(opts)
        if not ok then return false, err, i - 1 end
    end
    return true
end

local function runVertical(n, dir, opts)
    -- dir = +1 up, -1 down
    local fn = (dir > 0) and stepUp or stepDown
    for i = 1, n do
        local ok, err = fn(opts)
        if not ok then return false, err, i - 1 end
    end
    return true
end

----------------------------------------------------------------------
-- World goTo
----------------------------------------------------------------------

function M.goTo(target, opts)
    opts = opts or {}
    if not (target and target.x and target.y and target.z) then
        return false, "target {x,y,z} required"
    end
    local pos = gpsPos(); if not pos then return false, "no gps" end

    -- X axis
    local dx = math.floor(target.x) - pos.x
    if dx ~= 0 then
        local axis = (dx > 0) and "+x" or "-x"
        local ok, err = M.faceAxis(axis, opts); if not ok then return false, err end
        ok, err = runForward(math.abs(dx), opts); if not ok then return false, err end
    end

    -- Z axis (refresh pos in case GPS drifted)
    pos = gpsPos() or pos
    local dz = math.floor(target.z) - pos.z
    if dz ~= 0 then
        local axis = (dz > 0) and "+z" or "-z"
        local ok, err = M.faceAxis(axis, opts); if not ok then return false, err end
        ok, err = runForward(math.abs(dz), opts); if not ok then return false, err end
    end

    -- Y axis last (vertical never needs facing).
    pos = gpsPos() or pos
    local dy = math.floor(target.y) - pos.y
    if dy ~= 0 then
        local ok, err = runVertical(math.abs(dy), dy > 0 and 1 or -1, opts)
        if not ok then return false, err end
    end

    pos = gpsPos() or pos
    return true, pos
end

return M
