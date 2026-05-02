-- Dispatcher service.
--
-- Runs on one node (config.dispatcher = true). When a selection is
-- queued the dispatcher counts idle workers and splits the volume into
-- N equal slices — one per worker — so all turtles mine in parallel.
--
-- Split model
--   volume split along longest horizontal axis (X or Z).
--   Each slice is assigned to one worker via mine_assign.
--   Sub-selections are tracked with parent_id; when all finish the
--   parent moves to "done" (or "partial" if any slice failed).
--
-- State machine (top-level selection)
--   queued → in_progress → done | partial | failed | cancelled
--
-- Sub-selections inherit the same states; they are invisible in the
-- selection_list reply (consumers see only the parent with part counts).

local log = dofile("/unison/kernel/log.lua")

local M = {}

local STATE_FILE    = "/unison/state/dispatcher.json"
local TICK_S        = 5
local ANNOUNCE_S    = 30
local WORKER_STALE_MS = 60 * 1000

----------------------------------------------------------------------
-- Persistent state
----------------------------------------------------------------------

local state = {
    queue       = {},  -- id → selection (top-level + sub-selections)
    assignments = {},  -- selectionId → workerId
    workers     = {},  -- workerId → {kind, idle, last_seen, position, fuel, home}
}

local function nowMs() return os.epoch and os.epoch("utc") or 0 end
local function lib()   return unison and unison.lib end

local function readJson(path)
    local L = lib()
    if L and L.fs and L.fs.readJson then return L.fs.readJson(path) end
    if not fs.exists(path) then return nil end
    local h = fs.open(path, "r"); if not h then return nil end
    local s = h.readAll(); h.close()
    local ok, t = pcall(textutils.unserializeJSON, s)
    return ok and t or nil
end

local function writeJson(path, data)
    local L = lib()
    if L and L.fs and L.fs.writeJson then return L.fs.writeJson(path, data) end
    local d = fs.getDir(path)
    if d ~= "" and not fs.exists(d) then fs.makeDir(d) end
    local h = fs.open(path, "w"); if not h then return false end
    h.write(textutils.serializeJSON(data)); h.close(); return true
end

local function persist()
    writeJson(STATE_FILE, {
        queue       = state.queue,
        assignments = state.assignments,
        workers     = state.workers,
    })
end

local function restore()
    local t = readJson(STATE_FILE)
    if type(t) ~= "table" then return end
    state.queue       = t.queue       or {}
    state.assignments = t.assignments or {}
    state.workers     = t.workers     or {}
end

----------------------------------------------------------------------
-- Worker helpers
----------------------------------------------------------------------

local function touchWorker(id, patch)
    if not id then return end
    state.workers[id] = state.workers[id] or { kind = "any", idle = true }
    local w = state.workers[id]
    if patch then for k, v in pairs(patch) do w[k] = v end end
    w.last_seen = nowMs()
end

local function isStale(w)
    return (nowMs() - (w.last_seen or 0)) > WORKER_STALE_MS
end

local function manhattan(a, b)
    if not (a and b and a.x and b.x) then return math.huge end
    return math.abs(a.x - b.x) + math.abs(a.y - b.y) + math.abs(a.z - b.z)
end

-- Returns list of {id, dist} for all idle, non-stale, unassigned workers
-- whose kind matches "mining" or "any". Sorted closest-to-point first.
local function idleWorkers(nearPoint)
    local taken = {}
    for _, wid in pairs(state.assignments) do taken[wid] = true end

    local out = {}
    for id, w in pairs(state.workers) do
        if w.idle and not isStale(w)
           and (w.kind == "mining" or w.kind == "any")
           and not taken[id] then
            out[#out + 1] = { id = id, dist = manhattan(w.position, nearPoint) }
        end
    end
    table.sort(out, function(a, b) return a.dist < b.dist end)
    return out
end

----------------------------------------------------------------------
-- Volume splitting
----------------------------------------------------------------------

-- Split vol into n roughly-equal slices along the longest horizontal
-- axis (X or Z). Returns a list of sub-volumes (may be < n if the
-- dimension is smaller than n).
local function splitVolume(vol, n)
    if n <= 1 then return { vol } end
    local dx = vol.max.x - vol.min.x + 1
    local dz = vol.max.z - vol.min.z + 1
    local slices = {}

    if dx >= dz then
        -- Split along X
        for i = 0, n - 1 do
            local x0 = vol.min.x + math.floor(dx * i / n)
            local x1 = vol.min.x + math.floor(dx * (i + 1) / n) - 1
            if x0 <= x1 then
                slices[#slices + 1] = {
                    min = { x = x0, y = vol.min.y, z = vol.min.z },
                    max = { x = x1, y = vol.max.y, z = vol.max.z },
                }
            end
        end
    else
        -- Split along Z
        for i = 0, n - 1 do
            local z0 = vol.min.z + math.floor(dz * i / n)
            local z1 = vol.min.z + math.floor(dz * (i + 1) / n) - 1
            if z0 <= z1 then
                slices[#slices + 1] = {
                    min = { x = vol.min.x, y = vol.min.y, z = z0 },
                    max = { x = vol.max.x, y = vol.max.y, z = z1 },
                }
            end
        end
    end
    return slices
end

----------------------------------------------------------------------
-- Dispatch
----------------------------------------------------------------------

-- Try to dispatch a top-level queued selection. Splits the volume
-- among however many idle workers are currently available and fires
-- mine_assign to each. Marks the selection in_progress immediately;
-- the parent tracks parts_total / parts_done / parts_failed.
local function dispatchMany(rpc, selId, sel)
    local vol = sel.volume
    if not (vol and vol.min and vol.max) then
        sel.state = "failed"
        sel.error  = "no volume in selection"
        persist()
        return
    end

    local workers = idleWorkers(vol.min)
    if #workers == 0 then return end   -- no workers yet; retry next tick

    local n      = #workers
    local slices = splitVolume(vol, n)
    n = #slices                        -- actual count (vol may be thin)

    sel.state       = "in_progress"
    sel.parts_total = n
    sel.parts_done  = 0
    sel.parts_failed = 0

    if n == 1 then
        -- Assign the whole volume without creating a sub-selection.
        local w = workers[1]
        state.assignments[selId]   = w.id
        state.workers[w.id].idle   = false
        local ok = pcall(rpc.send, w.id, {
            type         = "mine_assign",
            selection_id = selId,
            volume       = vol,
            name         = sel.name,
            return_home  = true,
        })
        if not ok then
            sel.state  = "queued"   -- rollback, try next tick
            sel.parts_total  = nil
            state.assignments[selId] = nil
            state.workers[w.id].idle = true
        else
            log.info("dispatcher", string.format("assigned %s → worker %s (1 slice)",
                selId, w.id))
        end
    else
        -- Assign each slice to one worker.
        local dispatched = 0
        for i, slice in ipairs(slices) do
            local w = workers[i]
            if not w then break end

            local subId  = selId .. ":" .. i
            local subSel = {
                id        = subId,
                parent_id = selId,
                name      = (sel.name or selId) .. " [" .. i .. "/" .. n .. "]",
                volume    = slice,
                state     = "in_progress",
            }
            state.queue[subId]       = subSel
            state.assignments[subId] = w.id
            state.workers[w.id].idle = false

            local ok, err = pcall(rpc.send, w.id, {
                type         = "mine_assign",
                selection_id = subId,
                volume       = slice,
                name         = subSel.name,
                return_home  = true,
            })
            if not ok then
                log.warn("dispatcher", "mine_assign to " .. w.id .. " failed: " .. tostring(err))
                subSel.state             = "failed"
                state.assignments[subId] = nil
                state.workers[w.id].idle = true
                sel.parts_failed         = sel.parts_failed + 1
            else
                dispatched = dispatched + 1
                log.info("dispatcher", string.format(
                    "assigned %s → worker %s (slice %d/%d)", subId, w.id, i, n))
            end
        end

        if dispatched == 0 then
            -- All sends failed; rollback to queued so tick retries.
            sel.state        = "queued"
            sel.parts_total  = nil
            sel.parts_done   = nil
            sel.parts_failed = nil
            for i = 1, n do state.queue[selId .. ":" .. i] = nil end
        elseif (sel.parts_failed or 0) >= n then
            sel.state = "failed"
        end
    end

    persist()
end

----------------------------------------------------------------------
-- Tick
----------------------------------------------------------------------

local function tick()
    local rpc = unison and unison.rpc
    if not rpc then return end

    for selId, sel in pairs(state.queue) do
        if (sel.state == "queued" or sel.state == "draft")
           and not sel.parent_id then
            dispatchMany(rpc, selId, sel)
        end
    end
end

----------------------------------------------------------------------
-- RPC handlers
----------------------------------------------------------------------

local function onParentPartDone(selId, ok)
    local parent = state.queue[selId]
    if not parent then return end
    if ok then
        parent.parts_done   = (parent.parts_done   or 0) + 1
    else
        parent.parts_failed = (parent.parts_failed or 0) + 1
    end
    local total = parent.parts_total or 0
    local done  = (parent.parts_done or 0) + (parent.parts_failed or 0)
    if done >= total then
        parent.state = (parent.parts_failed or 0) == 0 and "done" or "partial"
        log.info("dispatcher", string.format(
            "selection %s complete: %d/%d ok, %d failed",
            selId, parent.parts_done or 0, total, parent.parts_failed or 0))
    end
end

local function installHandlers()
    local rpc = unison and unison.rpc
    if not rpc then return end

    -- selection_queue { selection }
    rpc.subscribe("selection_queue", function(msg, env)
        if type(msg.selection) ~= "table" or not msg.selection.id then
            rpc.reply(env, { type = "selection_reply", ok = false, err = "bad payload" })
            return
        end
        local sel = msg.selection
        sel.state = "queued"
        state.queue[sel.id] = sel
        persist()
        log.info("dispatcher", "queued " .. sel.id ..
            " (" .. tostring(sel.name or "?") .. ")")
        rpc.reply(env, { type = "selection_reply", ok = true, id = sel.id })
    end)

    -- selection_cancel { id }
    rpc.subscribe("selection_cancel", function(msg, env)
        local id = msg.id

        -- Abort all sub-selections first.
        for subId, subSel in pairs(state.queue) do
            if subSel.parent_id == id and subSel.state == "in_progress" then
                subSel.state = "cancelled"
                local wid = state.assignments[subId]
                if wid then
                    pcall(rpc.send, wid, { type = "mine_abort", selection_id = subId })
                    state.assignments[subId] = nil
                    if state.workers[wid] then state.workers[wid].idle = true end
                end
            end
        end

        -- Abort direct assignment (n=1 path, no sub-selections).
        local wid = state.assignments[id]
        if wid then
            pcall(rpc.send, wid, { type = "mine_abort", selection_id = id })
            state.assignments[id] = nil
            if state.workers[wid] then state.workers[wid].idle = true end
        end

        if state.queue[id] then state.queue[id].state = "cancelled" end
        persist()
        rpc.reply(env, { type = "selection_reply", ok = true, id = id })
    end)

    -- selection_list {} — returns top-level selections with part counts.
    rpc.subscribe("selection_list", function(msg, env)
        -- Gather sub-selection summaries per parent.
        local subInfo = {}
        for subId, subSel in pairs(state.queue) do
            if subSel.parent_id then
                local p = subSel.parent_id
                subInfo[p] = subInfo[p] or {}
                subInfo[p][#subInfo[p] + 1] = {
                    id     = subId,
                    state  = subSel.state,
                    volume = subSel.volume,
                    worker = state.assignments[subId],
                }
            end
        end
        local out = {}
        for id, s in pairs(state.queue) do
            if not s.parent_id then
                local entry = {}
                for k, v in pairs(s) do entry[k] = v end
                entry.parts = subInfo[id]
                out[#out + 1] = entry
            end
        end
        rpc.reply(env, { type = "selection_reply", ok = true,
                          selections = out, workers = state.workers })
    end)

    -- worker_register { kind, position, fuel, home, capabilities }
    rpc.subscribe("worker_register", function(msg, env)
        local id = tostring(env.from or msg.from or "?")
        touchWorker(id, {
            kind         = msg.kind or "any",
            idle         = msg.idle ~= false,
            position     = msg.position,
            fuel         = msg.fuel,
            home         = msg.home,
            capabilities = msg.capabilities,
        })
        persist()
        log.info("dispatcher", "worker registered: " .. id ..
            " kind=" .. tostring(msg.kind))
        rpc.reply(env, { type = "worker_reply", ok = true })
    end)

    rpc.subscribe("worker_idle", function(msg, env)
        local id = tostring(env.from or msg.from or "?")
        touchWorker(id, {
            idle     = true,
            position = msg.position,
            fuel     = msg.fuel,
        })
        rpc.reply(env, { type = "worker_reply", ok = true })
    end)

    rpc.subscribe("worker_busy", function(msg, env)
        local id = tostring(env.from or msg.from or "?")
        touchWorker(id, {
            idle     = false,
            position = msg.position,
            fuel     = msg.fuel,
        })
        rpc.reply(env, { type = "worker_reply", ok = true })
    end)

    -- mine_done { selection_id, ok, err? }
    rpc.subscribe("mine_done", function(msg, env)
        local id  = msg.selection_id
        local sel = id and state.queue[id]

        if sel then
            sel.state = msg.ok and "done" or "failed"
            sel.error = msg.err

            if sel.parent_id then
                onParentPartDone(sel.parent_id, msg.ok)
            end
        end

        local wid = state.assignments[id]
        state.assignments[id] = nil
        if wid and state.workers[wid] then
            state.workers[wid].idle = true
        end

        persist()
        log.info("dispatcher", "mine_done " .. tostring(id) ..
            " ok=" .. tostring(msg.ok))
        rpc.reply(env, { type = "mine_done_reply", ok = true })
    end)
end

----------------------------------------------------------------------
-- Public lifecycle
----------------------------------------------------------------------

function M.start(cfg)
    restore()
    installHandlers()
    local qn = 0; for _ in pairs(state.queue)   do qn = qn + 1 end
    local wn = 0; for _ in pairs(state.workers) do wn = wn + 1 end
    log.info("dispatcher", "online; queued=" .. qn .. " workers=" .. wn)
end

function M.tickLoop()
    while true do
        sleep(TICK_S)
        local ok, err = pcall(tick)
        if not ok then
            log.warn("dispatcher", "tick error: " .. tostring(err))
        end
    end
end

function M.announceLoop()
    while true do
        local rpc = unison and unison.rpc
        if rpc and rpc.broadcast then
            pcall(rpc.broadcast, {
                type = "dispatcher_announce",
                from = tostring(os.getComputerID()),
                kind = "dispatcher",
                ts   = os.epoch("utc"),
            })
        end
        sleep(ANNOUNCE_S)
    end
end

function M.snapshot()
    return {
        queue       = state.queue,
        assignments = state.assignments,
        workers     = state.workers,
    }
end

return M
