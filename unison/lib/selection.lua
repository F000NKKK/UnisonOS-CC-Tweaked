-- unison.lib.selection — WorldEdit-style 3D region marking.
--
-- A Volume is an axis-aligned bounding box in world coordinates with
-- a small set of mutating operations (expand / contract / shift /
-- slice). A Selection wraps a Volume with metadata (id, name, owner,
-- state, history) and persists to /unison/state/selections.json so
-- the surveyor pocket app, the dispatcher and shell tools all share
-- the same selection store.
--
-- Selection state machine:
--   draft        — being edited; not eligible for the dispatcher
--   queued       — handed to the dispatcher; waiting for an idle turtle
--   in_progress  — a turtle has accepted the assignment
--   done         — turtle returned home, volume fully cleared
--   cancelled    — user-aborted before completion
--
-- History:
--   { kind = "set_p1",      p = {x,y,z},      ts = ms }
--   { kind = "set_p2",      p = {x,y,z},      ts = ms }
--   { kind = "expand",      axis = "+y",      delta = 10, ts = ms }
--   { kind = "contract",    axis = "-z",      delta = 3,  ts = ms }
--   { kind = "shift",       d = {x,y,z},      ts = ms }
--   { kind = "slice",       axis = "+x", n = 5, ts = ms }
--   { kind = "state",       to = "queued",    ts = ms }
--
-- Pure module: no GPS, no turtle, no peripherals. Volumes can be built
-- and manipulated in tests / on a server with no CC environment.

local M = {}

local STATE_FILE = "/unison/state/selections.json"
local ACTIVE_FILE = "/unison/state/selection.active"

local AXES = { x = true, y = true, z = true }

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------

local function nowMs()
    return (os and os.epoch) and os.epoch("utc") or 0
end

local function lib() return unison and unison.lib end

local function readJson(path)
    local L = lib()
    if L and L.fs and L.fs.readJson then return L.fs.readJson(path) end
    if not (fs and fs.exists and fs.exists(path)) then return nil end
    local h = fs.open(path, "r"); if not h then return nil end
    local s = h.readAll(); h.close()
    local ok, t = pcall(textutils.unserializeJSON, s)
    return ok and t or nil
end

local function writeJson(path, data)
    local L = lib()
    if L and L.fs and L.fs.writeJson then return L.fs.writeJson(path, data) end
    local d = fs and fs.getDir and fs.getDir(path) or ""
    if d ~= "" and fs and not fs.exists(d) then fs.makeDir(d) end
    local h = fs.open(path, "w"); if not h then return false end
    h.write(textutils.serializeJSON(data)); h.close()
    return true
end

local function iRound(n)
    n = tonumber(n) or 0
    if n >= 0 then return math.floor(n + 0.5) end
    return math.ceil(n - 0.5)
end

local function copyXYZ(p)
    return { x = iRound(p.x), y = iRound(p.y), z = iRound(p.z) }
end

-- Parse "x" / "+x" / "-y" → ("x", +1) / ("y", -1). Bare axis defaults
-- to +. Returns nil on garbage.
local function parseAxis(s)
    if type(s) ~= "string" then return nil end
    local sign, axis = s:match("^([%+%-]?)([xyzXYZ])$")
    if not axis then return nil end
    axis = axis:lower()
    return axis, (sign == "-") and -1 or 1
end

local function genId()
    -- uuid-ish enough for local / per-server uniqueness.
    local r = math.random
    return string.format("sel-%x-%x-%x", nowMs() % 0xFFFFFF, r(0, 0xFFFF), r(0, 0xFFFF))
end

----------------------------------------------------------------------
-- Volume (AABB)
----------------------------------------------------------------------

local Volume = {}
Volume.__index = Volume
M.Volume = Volume

local function normalizeAabb(a, b)
    return {
        min = {
            x = math.min(a.x, b.x),
            y = math.min(a.y, b.y),
            z = math.min(a.z, b.z),
        },
        max = {
            x = math.max(a.x, b.x),
            y = math.max(a.y, b.y),
            z = math.max(a.z, b.z),
        },
    }
end

function M.volume(min, max)
    if not (min and max) then return nil end
    local n = normalizeAabb(copyXYZ(min), copyXYZ(max))
    return setmetatable(n, Volume)
end

function M.volumeFromCorners(p1, p2) return M.volume(p1, p2) end

function Volume:clone()
    return M.volume(self.min, self.max)
end

function Volume:dimensions()
    return self.max.x - self.min.x + 1,
           self.max.y - self.min.y + 1,
           self.max.z - self.min.z + 1
end

function Volume:blockCount()
    local w, h, d = self:dimensions()
    return w * h * d
end

function Volume:contains(x, y, z)
    return x >= self.min.x and x <= self.max.x
       and y >= self.min.y and y <= self.max.y
       and z >= self.min.z and z <= self.max.z
end

-- Move the relevant face by `delta` blocks in the axis sign's direction.
-- "+x" delta=10 → max.x += 10. "-y" delta=10 → min.y -= 10.
function Volume:expand(axisSpec, delta)
    local axis, sign = parseAxis(axisSpec)
    if not axis then return false, "bad axis: " .. tostring(axisSpec) end
    delta = math.floor(tonumber(delta) or 0)
    if delta == 0 then return self end
    if sign > 0 then
        self.max[axis] = self.max[axis] + delta
    else
        self.min[axis] = self.min[axis] - delta
    end
    -- Re-normalize: caller may have driven min past max with negative
    -- delta on contract; clamp to a 1-block slab so we never invert.
    if self.min[axis] > self.max[axis] then
        local mid = math.floor((self.min[axis] + self.max[axis]) / 2)
        self.min[axis], self.max[axis] = mid, mid
    end
    return self
end

-- Inverse of expand: pull the relevant face inward by `delta`.
function Volume:contract(axisSpec, delta)
    return self:expand(axisSpec, -math.abs(tonumber(delta) or 0))
end

function Volume:shift(dx, dy, dz)
    dx = math.floor(tonumber(dx) or 0)
    dy = math.floor(tonumber(dy) or 0)
    dz = math.floor(tonumber(dz) or 0)
    self.min.x = self.min.x + dx; self.max.x = self.max.x + dx
    self.min.y = self.min.y + dy; self.max.y = self.max.y + dy
    self.min.z = self.min.z + dz; self.max.z = self.max.z + dz
    return self
end

-- Keep only `n` blocks along axis on the side specified by sign.
-- "+y" 1 → top slab; "-y" 1 → bottom slab.
function Volume:slice(axisSpec, n)
    local axis, sign = parseAxis(axisSpec)
    if not axis then return false, "bad axis: " .. tostring(axisSpec) end
    n = math.max(1, math.floor(tonumber(n) or 1))
    local span = self.max[axis] - self.min[axis] + 1
    if n >= span then return self end
    if sign > 0 then
        self.min[axis] = self.max[axis] - n + 1
    else
        self.max[axis] = self.min[axis] + n - 1
    end
    return self
end

-- For serialization: a plain table of integers, no metatable.
function Volume:toTable()
    return { min = copyXYZ(self.min), max = copyXYZ(self.max) }
end

function M.volumeFromTable(t)
    if not (t and t.min and t.max) then return nil end
    return M.volume(t.min, t.max)
end

----------------------------------------------------------------------
-- Selection (named, persistable, with history)
----------------------------------------------------------------------

local Selection = {}
Selection.__index = Selection
M.Selection = Selection

local function newSelection(opts)
    opts = opts or {}
    return setmetatable({
        id      = opts.id or genId(),
        name    = opts.name or "untitled",
        owner   = opts.owner or "local",
        p1      = nil,
        p2      = nil,
        volume  = nil,
        state   = "draft",
        history = {},
        created_at = nowMs(),
        updated_at = nowMs(),
    }, Selection)
end

function M.new(opts) return newSelection(opts) end

local function pushHistory(self, entry)
    entry.ts = nowMs()
    self.history[#self.history + 1] = entry
    self.updated_at = entry.ts
end

local function recompute(self)
    if self.p1 and self.p2 then
        self.volume = M.volumeFromCorners(self.p1, self.p2)
    end
end

function Selection:setP1(coord)
    if not coord then return false, "coord required" end
    self.p1 = copyXYZ(coord)
    recompute(self)
    pushHistory(self, { kind = "set_p1", p = copyXYZ(coord) })
    return self
end

function Selection:setP2(coord)
    if not coord then return false, "coord required" end
    self.p2 = copyXYZ(coord)
    recompute(self)
    pushHistory(self, { kind = "set_p2", p = copyXYZ(coord) })
    return self
end

local function ensureVolume(self)
    if not self.volume then return false, "no volume yet (set p1 + p2 first)" end
    return self.volume
end

function Selection:expand(axisSpec, delta)
    local v, err = ensureVolume(self); if not v then return false, err end
    local ok, e = v:expand(axisSpec, delta)
    if ok == false then return false, e end
    pushHistory(self, { kind = "expand", axis = axisSpec, delta = delta })
    return self
end

function Selection:contract(axisSpec, delta)
    local v, err = ensureVolume(self); if not v then return false, err end
    local ok, e = v:contract(axisSpec, delta)
    if ok == false then return false, e end
    pushHistory(self, { kind = "contract", axis = axisSpec, delta = delta })
    return self
end

function Selection:shift(dx, dy, dz)
    local v, err = ensureVolume(self); if not v then return false, err end
    v:shift(dx, dy, dz)
    pushHistory(self, { kind = "shift", d = { x = dx, y = dy, z = dz } })
    return self
end

function Selection:slice(axisSpec, n)
    local v, err = ensureVolume(self); if not v then return false, err end
    local ok, e = v:slice(axisSpec, n)
    if ok == false then return false, e end
    pushHistory(self, { kind = "slice", axis = axisSpec, n = n })
    return self
end

local STATES = { draft = true, queued = true, in_progress = true,
                  done = true, cancelled = true }

function Selection:setState(s)
    if not STATES[s] then return false, "bad state: " .. tostring(s) end
    if s == self.state then return self end
    self.state = s
    pushHistory(self, { kind = "state", to = s })
    return self
end

function Selection:queue()      return self:setState("queued") end
function Selection:cancel()     return self:setState("cancelled") end

function Selection:summary()
    local v = self.volume
    if not v then
        return {
            id = self.id, name = self.name, state = self.state,
            volume = nil, blocks = 0, dimensions = nil,
        }
    end
    local w, h, d = v:dimensions()
    return {
        id = self.id, name = self.name, state = self.state,
        volume = v:toTable(),
        dimensions = { w, h, d },
        blocks = v:blockCount(),
        owner = self.owner,
    }
end

function Selection:toTable()
    return {
        id = self.id, name = self.name, owner = self.owner,
        p1 = self.p1, p2 = self.p2,
        volume = self.volume and self.volume:toTable() or nil,
        state = self.state,
        history = self.history,
        created_at = self.created_at,
        updated_at = self.updated_at,
    }
end

function M.fromTable(t)
    if type(t) ~= "table" or not t.id then return nil end
    local s = newSelection({ id = t.id, name = t.name, owner = t.owner })
    s.p1 = t.p1 and copyXYZ(t.p1) or nil
    s.p2 = t.p2 and copyXYZ(t.p2) or nil
    s.volume = t.volume and M.volumeFromTable(t.volume) or nil
    s.state = STATES[t.state] and t.state or "draft"
    s.history = type(t.history) == "table" and t.history or {}
    s.created_at = tonumber(t.created_at) or 0
    s.updated_at = tonumber(t.updated_at) or 0
    return s
end

----------------------------------------------------------------------
-- Local store: /unison/state/selections.json keyed by id.
----------------------------------------------------------------------

local function loadAll()
    local raw = readJson(STATE_FILE)
    if type(raw) ~= "table" then return {} end
    return raw
end

local function saveAll(map) return writeJson(STATE_FILE, map) end

function M.list()
    local out = {}
    for id, t in pairs(loadAll()) do
        local sel = M.fromTable(t); if sel then out[#out + 1] = sel end
    end
    table.sort(out, function(a, b) return (a.updated_at or 0) > (b.updated_at or 0) end)
    return out
end

function M.load(id)
    if not id then return nil end
    local all = loadAll()
    return all[id] and M.fromTable(all[id]) or nil
end

function Selection:save()
    local all = loadAll()
    all[self.id] = self:toTable()
    return saveAll(all) and self or nil
end

function Selection:remove()
    local all = loadAll()
    all[self.id] = nil
    return saveAll(all)
end

----------------------------------------------------------------------
-- "Active" selection — a single id stored separately so shell ops
-- like `select expand +y 10` know which selection to mutate without
-- the user retyping the id every time.
----------------------------------------------------------------------

function M.activeId()
    local s = readJson(ACTIVE_FILE)
    if type(s) == "table" and type(s.id) == "string" then return s.id end
    return nil
end

function M.setActive(id) return writeJson(ACTIVE_FILE, { id = id }) end

function M.active()
    local id = M.activeId(); if not id then return nil end
    return M.load(id)
end

return M
