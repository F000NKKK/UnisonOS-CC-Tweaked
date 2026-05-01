-- unison.lib.atlas — client for the server-side world atlas.
--
-- Every device streams discovered blocks, mined blocks, movement
-- events and landmarks to the VPS, which keeps a single shared world
-- model. Use this module to:
--   * stream observations:   atlas.recordBlocks{ {x,y,z,name}, ... }
--   * log activity events:   atlas.logEvent{ kind="dig", x=..., y=...}
--   * query blocks:          atlas.queryBlocks{ bbox = {x1,y1,z1,x2,y2,z2} }
--   * landmarks:             atlas.addLandmark{...} / atlas.landmarks()
--   * pathfinding:           atlas.path(from, to) -> { {x,y,z}, ... }
--
-- All calls go through unison.lib.http (cache-busted, multi-source) and
-- the configured pm_sources list. Failures don't propagate; observation
-- streams batch-up so a 1k-block scan = ~5 HTTP requests, not 1k.

local httpLib = unison and unison.lib and unison.lib.http
                or dofile("/unison/lib/http.lua")
local jsonLib = unison and unison.lib and unison.lib.json
                or dofile("/unison/lib/json.lua")
local sources = dofile("/unison/pm/sources.lua")

local M = {}

local BATCH_SIZE   = 256       -- flush after N pending blocks
local FLUSH_EVERY  = 5         -- ...or every N seconds, whichever first

local pending = { blocks = {}, events = {} }
local lastFlush = 0

local function bearer()
    return (unison and unison.config and unison.config.api_token)
        or (function()
            local h = fs.open("/unison/state/api_token", "r")
            if not h then return nil end
            local t = h.readAll(); h.close()
            return t and t:match("^%s*(.-)%s*$") or nil
        end)()
end

-- POST <base>/api/atlas/<endpoint> JSON body. Tries each source until
-- one returns 2xx. Returns body, code or nil, err.
local function post(endpoint, body)
    local list = sources.list()
    local headers = {}
    local tok = bearer()
    if tok then headers["Authorization"] = "Bearer " .. tok end
    local lastErr
    for _, base in ipairs(list) do
        local resp, code = httpLib.post(base .. "/api/atlas/" .. endpoint,
            body, headers)
        if resp and code and code < 400 then return resp, code end
        lastErr = resp or ("status " .. tostring(code))
    end
    return nil, lastErr or "all sources failed"
end

local function get(endpoint)
    local list = sources.list()
    local headers = {}
    local tok = bearer()
    if tok then headers["Authorization"] = "Bearer " .. tok end
    local lastErr
    for _, base in ipairs(list) do
        local body, code = httpLib.get(base .. "/api/atlas/" .. endpoint, headers)
        if body then return body, code end
        lastErr = code
    end
    return nil, lastErr
end

local function deviceId()
    return tostring((unison and unison.id) or os.getComputerID())
end

----------------------------------------------------------------------
-- Block streaming (batched)
----------------------------------------------------------------------

local function flushBlocks()
    if #pending.blocks == 0 then return end
    local batch = pending.blocks
    pending.blocks = {}
    pcall(post, "blocks", { by = deviceId(), blocks = batch })
end

local function flushEvents()
    if #pending.events == 0 then return end
    local batch = pending.events
    pending.events = {}
    pcall(post, "events", { by = deviceId(), events = batch })
end

function M.flush()
    flushBlocks()
    flushEvents()
    lastFlush = os.epoch("utc")
end

local function autoFlush()
    if #pending.blocks >= BATCH_SIZE then flushBlocks() end
    if #pending.events >= BATCH_SIZE then flushEvents() end
    local now = os.epoch("utc")
    if now - lastFlush > FLUSH_EVERY * 1000 then M.flush() end
end

-- Append one block observation to the outbound batch.
-- block = { x, y, z, name }
function M.recordBlock(block)
    if not (block and block.x and block.y and block.z) then return end
    pending.blocks[#pending.blocks + 1] = {
        x = block.x, y = block.y, z = block.z,
        name = block.name or "minecraft:unknown",
    }
    autoFlush()
end

function M.recordBlocks(blocks)
    for _, b in ipairs(blocks or {}) do M.recordBlock(b) end
end

-- Activity event. kind = "move" | "dig" | "place" | "scan_start" | ...
function M.logEvent(ev)
    if not ev or not ev.kind then return end
    pending.events[#pending.events + 1] = ev
    autoFlush()
end

----------------------------------------------------------------------
-- Queries
----------------------------------------------------------------------

local function decode(body)
    if not body then return nil end
    return jsonLib.decode(body)
end

function M.queryBlocks(opts)
    opts = opts or {}
    local q = {}
    if opts.bbox then
        local b = opts.bbox
        q[#q + 1] = "bbox=" .. table.concat({b[1], b[2], b[3], b[4], b[5], b[6]}, ",")
    end
    if opts.kinds  then q[#q + 1] = "kinds=" .. table.concat(opts.kinds, ",") end
    if opts.name   then q[#q + 1] = "name=" .. tostring(opts.name) end
    if opts.limit  then q[#q + 1] = "limit=" .. tostring(opts.limit) end
    local body = get("blocks" .. (#q > 0 and ("?" .. table.concat(q, "&")) or ""))
    local d = decode(body) or {}
    return d.blocks or {}
end

function M.stats()
    return decode(get("stats")) or {}
end

function M.landmarks()
    local d = decode(get("landmarks")) or {}
    return d.items or {}
end

function M.addLandmark(lm)
    if not (lm and lm.name) then return false, "name required" end
    lm.by = lm.by or deviceId()
    return post("landmarks", lm)
end

function M.removeLandmark(name)
    local list = sources.list()
    local headers = {}
    local tok = bearer()
    if tok then headers["Authorization"] = "Bearer " .. tok end
    if not http then return nil, "no http" end
    for _, base in ipairs(list) do
        local r = http.request {
            url = base .. "/api/atlas/landmarks/" .. name,
            method = "DELETE", headers = headers,
        }
        if r then return true end
    end
    return false
end

-- Replace this device's storage snapshot on the server. items = list of
-- { name = "minecraft:stone", count = 64 } pairs (one row per item id).
-- The server clears any previous rows for this device before inserting.
function M.pushStorage(items)
    return post("storage", { by = deviceId(), items = items or {} })
end

-- Aggregated query: returns { totals = [...], breakdown = [...] }.
-- opts.name / opts.device / opts.pattern are forwarded as query params.
function M.queryStorage(opts)
    opts = opts or {}
    local q = {}
    if opts.name    then q[#q + 1] = "name=" .. tostring(opts.name) end
    if opts.device  then q[#q + 1] = "device=" .. tostring(opts.device) end
    if opts.pattern then q[#q + 1] = "pattern=" .. tostring(opts.pattern) end
    return decode(get("storage" .. (#q > 0 and ("?" .. table.concat(q, "&")) or ""))) or {}
end

function M.path(from, to)
    local q = string.format("path?from=%d,%d,%d&to=%d,%d,%d",
        from.x, from.y, from.z, to.x, to.y, to.z)
    local d = decode(get(q))
    if not d or not d.path then return nil end
    return d.path
end

return M
