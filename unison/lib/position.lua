-- unison.lib.position — relative position + facing tracker for
-- turtle apps. mine, scanner, patrol etc all carried their own copy
-- of the same {x, y, z, facing} state machine; this is the shared one.
--
-- Convention (matches every turtle app):
--   facing 0 = +x (forward at boot)
--   facing 1 = +z (right)
--   facing 2 = -x (back)
--   facing 3 = -z (left)
--
-- The four cardinal direction offsets:

local M = {}

M.DIR = {
    [0] = { dx =  1, dz =  0 },
    [1] = { dx =  0, dz =  1 },
    [2] = { dx = -1, dz =  0 },
    [3] = { dx =  0, dz = -1 },
}

-- Pure facing-math helpers (no I/O, no turtle calls).
function M.offset(facing) local d = M.DIR[facing % 4]; return d.dx, d.dz end
function M.turnLeft(f)  return (f + 3) % 4 end
function M.turnRight(f) return (f + 1) % 4 end
function M.opposite(f)  return (f + 2) % 4 end

-- Manhattan distance from (x, y, z) to origin (0,0,0).
function M.distance(x, y, z)
    return math.abs(x or 0) + math.abs(y or 0) + math.abs(z or 0)
end

----------------------------------------------------------------------
-- Stateful Position object — wraps {x, y, z, facing} with a persist
-- callback the caller can use to write to disk after every move.
--   local pos = Position.new({x=0, y=0, z=0, facing=0}, function(p) ... end)
--   pos:turnLeft()          -- updates facing AND calls persist
--   pos:advance()           -- updates x/z based on facing AND persists
--   pos:climb(dy)           -- updates y AND persists
--   pos:faceDir(target, doTurn)
--      where doTurn(turn_kind) is "left"|"right"|"back" and the caller
--      issues the actual turtle.turnLeft/Right calls.
----------------------------------------------------------------------

local Position = {}; Position.__index = Position

function M.new(initial, persist)
    initial = initial or {}
    return setmetatable({
        x = initial.x or 0,
        y = initial.y or 0,
        z = initial.z or 0,
        facing = initial.facing or 0,
        _persist = persist or function() end,
    }, Position)
end

function Position:_save()
    -- The persist callback receives a plain table — apps usually want
    -- to merge it into a larger job/state object before writing.
    self._persist({
        x = self.x, y = self.y, z = self.z, facing = self.facing,
    })
end

function Position:turnLeft()  self.facing = M.turnLeft(self.facing);  self:_save() end
function Position:turnRight() self.facing = M.turnRight(self.facing); self:_save() end

-- Apply a forward step in the current facing direction.
function Position:advance(steps)
    steps = steps or 1
    local dx, dz = M.offset(self.facing)
    self.x = self.x + dx * steps
    self.z = self.z + dz * steps
    self:_save()
end

-- Apply a backward step (facing unchanged).
function Position:retreat(steps)
    steps = steps or 1
    local dx, dz = M.offset(self.facing)
    self.x = self.x - dx * steps
    self.z = self.z - dz * steps
    self:_save()
end

-- Vertical move (y axis); positive = up.
function Position:climb(dy)  self.y = self.y + (dy or 1); self:_save() end
function Position:descend(dy) self.y = self.y - (dy or 1); self:_save() end

-- Distance to (0,0,0) — caller can reuse for fuel-home reserve calcs.
function Position:distanceHome()
    return M.distance(self.x, self.y, self.z)
end

-- Rotate to face `target` direction. Calls turnFn("left"|"right"|"back")
-- once, twice, or once depending on shortest path. The fn does the
-- actual turtle.turnLeft / turtle.turnRight calls AND the corresponding
-- pos:turnLeft/turnRight() bookkeeping (so the position stays in sync).
function Position:faceDir(target, turnFn)
    local diff = (target - self.facing) % 4
    if diff == 0 then return end
    if diff == 1 then turnFn("right")
    elseif diff == 2 then turnFn("right"); turnFn("right")
    else turnFn("left") end
end

return M
