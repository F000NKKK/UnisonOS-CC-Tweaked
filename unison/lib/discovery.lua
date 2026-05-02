-- unison.lib.discovery — known-peer cache.
--
-- Some services (the dispatcher in particular) want to be found by
-- workers without manual config. The dispatcher periodically POSTs a
-- broadcast `dispatcher_announce { id, kind = "dispatcher" }`; every
-- node listens and stores the (id, last_seen, kind) tuple here. When
-- a worker needs to send work-related RPCs it asks discovery.lookup
-- ("dispatcher") and falls back to unison.config.dispatcher_id.
--
-- Persisted at /unison/state/discovery.json so the cache survives
-- reboots (the dispatcher might be down briefly but the worker still
-- knows where it WAS).

local M = {}

local STATE_FILE = "/unison/state/discovery.json"
local STALE_MS = 5 * 60 * 1000   -- 5 min without an announce → treat
                                  -- the entry as best-effort only

local function lib() return unison and unison.lib end
local function nowMs() return os.epoch and os.epoch("utc") or 0 end

local function readJson()
    local L = lib(); if L and L.fs and L.fs.readJson then return L.fs.readJson(STATE_FILE) end
    if not fs.exists(STATE_FILE) then return nil end
    local h = fs.open(STATE_FILE, "r"); if not h then return nil end
    local s = h.readAll(); h.close()
    local ok, t = pcall(textutils.unserializeJSON, s); return ok and t or nil
end

local function writeJson(t)
    local L = lib(); if L and L.fs and L.fs.writeJson then return L.fs.writeJson(STATE_FILE, t) end
    if not fs.exists("/unison/state") then fs.makeDir("/unison/state") end
    local h = fs.open(STATE_FILE, "w"); if not h then return false end
    h.write(textutils.serializeJSON(t)); h.close(); return true
end

local _cache = nil
local function load()
    if _cache then return _cache end
    _cache = readJson() or {}
    return _cache
end

local function save() writeJson(load()) end

----------------------------------------------------------------------
-- Public
----------------------------------------------------------------------

-- Note that we saw a peer of `kind` at id `id` (with optional extra
-- info preserved on the entry). Updates last_seen, persists.
function M.announce(kind, id, extra)
    if not (kind and id) then return end
    local c = load()
    c[kind] = c[kind] or {}
    c[kind][tostring(id)] = {
        id = tostring(id),
        last_seen = nowMs(),
        extra = extra,
    }
    save()
end

-- Return id of the freshest peer of `kind`, or nil.
function M.lookup(kind)
    local c = load(); if not c[kind] then return nil end
    local best, bestTs
    for id, entry in pairs(c[kind]) do
        local ts = tonumber(entry.last_seen) or 0
        if not best or ts > bestTs then best, bestTs = id, ts end
    end
    if not best then return nil end
    return best, (nowMs() - bestTs) > STALE_MS
end

-- Return list of all known peers of a kind: { {id, last_seen, age_ms, extra}, ... }
function M.list(kind)
    local out = {}
    local c = load(); if not c[kind] then return out end
    local n = nowMs()
    for id, entry in pairs(c[kind]) do
        out[#out + 1] = {
            id = id, last_seen = entry.last_seen,
            age_ms = n - (entry.last_seen or 0),
            extra = entry.extra,
        }
    end
    table.sort(out, function(a, b) return a.last_seen > b.last_seen end)
    return out
end

function M.clear(kind)
    local c = load(); c[kind] = nil; save()
end

return M
