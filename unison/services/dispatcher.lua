-- Dispatcher service.
--
-- Runs on one node in the fleet (set unison.config.dispatcher = true)
-- and matches queued mining selections against idle worker turtles.
--
-- Wire model:
--   Surveyor / shell  ──selection_queue──→  Dispatcher
--   Workers           ──worker_register──→  Dispatcher (once at boot)
--   Workers           ──worker_idle/busy─→  Dispatcher (status changes)
--   Workers           ──mine_done────────→  Dispatcher (completion)
--   Dispatcher        ──mine_assign──────→  Worker
--
-- The tick loop walks queued selections, finds the closest idle
-- worker whose `kind` matches "mining" (or the selection's required
-- kind), and sends mine_assign. Worker accepts → busy → mines →
-- mine_done → dispatcher marks selection done and worker idle again.
--
-- All state in /unison/state/dispatcher.json so a reboot doesn't lose
-- in-flight assignments. Tick interval is 5 s — fast enough for an
-- interactive surveyor, slow enough not to spam the bus.

local log  = dofile("/unison/kernel/log.lua")
local sels = nil      -- lazy: lib.selection (loaded after kernel.lib is up)

local M = {}

local STATE_FILE = "/unison/state/dispatcher.json"
local TICK_S = 5
local WORKER_STALE_MS = 60 * 1000   -- workers we haven't heard from in 60 s
                                    -- are dropped from the idle pool.

----------------------------------------------------------------------
-- Persistent + in-memory state
----------------------------------------------------------------------

local state = {
    queue       = {},  -- selectionId-keyed map of queued selections
    assignments = {},  -- selectionId → workerId (in-progress)
    workers     = {},  -- workerId → { kind, idle, last_seen, position,
                       --              fuel, home, capabilities }
}

local function nowMs() return os.epoch and os.epoch("utc") or 0 end

local function lib() return unison and unison.lib end

local function readJson(path)
    local L = lib(); if L and L.fs and L.fs.readJson then return L.fs.readJson(path) end
    if not fs.exists(path) then return nil end
    local h = fs.open(path, "r"); if not h then return nil end
    local s = h.readAll(); h.close()
    local ok, t = pcall(textutils.unserializeJSON, s); return ok and t or nil
end

local function writeJson(path, data)
    local L = lib(); if L and L.fs and L.fs.writeJson then return L.fs.writeJson(path, data) end
    local d = fs.getDir(path)
    if d ~= "" and not fs.exists(d) then fs.makeDir(d) end
    local h = fs.open(path, "w"); if not h then return false end
    h.write(textutils.serializeJSON(data)); h.close(); return true
end

local function persist() writeJson(STATE_FILE, {
    queue = state.queue, assignments = state.assignments, workers = state.workers,
}) end

local function restore()
    local t = readJson(STATE_FILE); if type(t) ~= "table" then return end
    state.queue       = t.queue       or {}
    state.assignments = t.assignments or {}
    state.workers     = t.workers     or {}
end

----------------------------------------------------------------------
-- Worker registry helpers
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

-- Manhattan distance between two world points, or large number if any
-- side is missing — keeps it usable for `min` comparisons.
local function manhattan(a, b)
    if not (a and b and a.x and b.x) then return math.huge end
    return math.abs(a.x - b.x) + math.abs(a.y - b.y) + math.abs(a.z - b.z)
end

local function pickWorker(selection)
    -- Match: kind == "mining" (or "any") AND idle AND not stale AND
    -- not currently assigned. Tie-break by manhattan distance from
    -- worker's position to selection volume's min corner.
    local volMin = selection.volume and selection.volume.min
    local best, bestDist
    for id, w in pairs(state.workers) do
        if w.idle and not isStale(w)
           and (w.kind == "mining" or w.kind == "any") then
            local taken = false
            for _, assignedTo in pairs(state.assignments) do
                if assignedTo == id then taken = true; break end
            end
            if not taken then
                local d = manhattan(w.position, volMin)
                if not best or d < bestDist then
                    best, bestDist = id, d
                end
            end
        end
    end
    return best
end

----------------------------------------------------------------------
-- Dispatch tick
----------------------------------------------------------------------

local function dispatchOne(rpc, selectionId, selection)
    if state.assignments[selectionId] then return false end   -- already assigned
    local workerId = pickWorker(selection)
    if not workerId then return false end

    local payload = {
        type = "mine_assign",
        selection_id = selectionId,
        volume = selection.volume,
        name = selection.name,
        return_home = true,        -- mine 3.0 reads /unison/state/home.json
    }
    local res = rpc.send(workerId, payload)
    if not (res and (res.ok or res.id)) then
        log.warn("dispatcher", "send mine_assign failed for " .. tostring(workerId))
        return false
    end

    state.assignments[selectionId] = workerId
    state.workers[workerId].idle = false
    selection.state = "in_progress"
    state.queue[selectionId] = selection
    persist()
    log.info("dispatcher", string.format("assigned %s → %s", selectionId, workerId))
    return true
end

local function tick()
    local rpc = unison and unison.rpc; if not rpc then return end
    -- Drop stale workers from the pool so we don't keep trying to
    -- assign to a turtle that vanished.
    for id, w in pairs(state.workers) do
        if isStale(w) and w.idle then
            -- keep the record (so reconnects pick up state), just
            -- don't consider it for matching this tick.
        end
    end
    for selId, sel in pairs(state.queue) do
        if sel.state == "queued" or sel.state == "draft" then
            dispatchOne(rpc, selId, sel)
        end
    end
end

----------------------------------------------------------------------
-- RPC handlers
----------------------------------------------------------------------

local function installHandlers()
    local rpc = unison and unison.rpc; if not rpc then return end

    -- selection_queue { selection = {...selection table...} }
    rpc.subscribe("selection_queue", function(msg, env)
        if type(msg.selection) ~= "table" or not msg.selection.id then
            rpc.reply(env, { type = "selection_reply", ok = false, err = "bad payload" })
            return
        end
        local sel = msg.selection
        sel.state = "queued"
        state.queue[sel.id] = sel
        persist()
        log.info("dispatcher", "queued " .. sel.id .. " (" ..
            tostring(sel.name or "?") .. ")")
        rpc.reply(env, { type = "selection_reply", ok = true, id = sel.id })
    end)

    rpc.subscribe("selection_cancel", function(msg, env)
        local id = msg.id
        if state.queue[id] then state.queue[id].state = "cancelled" end
        local worker = state.assignments[id]
        if worker then
            -- Tell the assigned worker to abort.
            rpc.send(worker, { type = "mine_abort", selection_id = id })
            state.assignments[id] = nil
            if state.workers[worker] then state.workers[worker].idle = true end
        end
        persist()
        rpc.reply(env, { type = "selection_reply", ok = true, id = id })
    end)

    rpc.subscribe("selection_list", function(msg, env)
        local out = {}
        for id, s in pairs(state.queue) do out[#out + 1] = s end
        rpc.reply(env, { type = "selection_reply", ok = true, selections = out,
                          assignments = state.assignments })
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
        log.info("dispatcher", "worker registered: " .. id .. " kind=" .. tostring(msg.kind))
        rpc.reply(env, { type = "worker_reply", ok = true })
    end)

    rpc.subscribe("worker_idle", function(msg, env)
        local id = tostring(env.from or msg.from or "?")
        touchWorker(id, { idle = true, position = msg.position, fuel = msg.fuel })
        rpc.reply(env, { type = "worker_reply", ok = true })
    end)

    rpc.subscribe("worker_busy", function(msg, env)
        local id = tostring(env.from or msg.from or "?")
        touchWorker(id, { idle = false, position = msg.position, fuel = msg.fuel })
        rpc.reply(env, { type = "worker_reply", ok = true })
    end)

    -- mine_done { selection_id, ok, err? } — turtle reports completion.
    rpc.subscribe("mine_done", function(msg, env)
        local id = msg.selection_id; if not id then return end
        local sel = state.queue[id]
        if sel then sel.state = msg.ok and "done" or "failed" end
        local worker = state.assignments[id]
        state.assignments[id] = nil
        if worker and state.workers[worker] then
            state.workers[worker].idle = true
        end
        persist()
        log.info("dispatcher", "mine_done " .. id .. " ok=" .. tostring(msg.ok))
        rpc.reply(env, { type = "mine_done_reply", ok = true })
    end)
end

----------------------------------------------------------------------
-- Public lifecycle
----------------------------------------------------------------------

function M.start(cfg)
    sels = unison and unison.lib and unison.lib.selection
    restore()
    installHandlers()
    log.info("dispatcher", "online; queue=" .. tostring(table.concat({}, ",")) ..
        " workers=" .. tostring(table.concat({}, ",")))
end

function M.tickLoop()
    while true do
        sleep(TICK_S)
        local ok, err = pcall(tick)
        if not ok then log.warn("dispatcher", "tick error: " .. tostring(err)) end
    end
end

-- Read-only state inspector for the shell `dispatcher` command.
function M.snapshot()
    return {
        queue       = state.queue,
        assignments = state.assignments,
        workers     = state.workers,
    }
end

return M
