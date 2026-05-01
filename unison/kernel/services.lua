-- Service manager.
--
-- Declarative systemd-style service supervision.
--
-- Each unit lives at /unison/services.d/<name>.lua and returns a table:
--   {
--     name        = "foo",                       -- defaults to filename
--     description = "what it does",
--     enabled     = true,                        -- if false, ignored at boot
--     roles       = { "any" },                   -- "any" or list of roles
--     deps        = { "bar" },                   -- units that must run first
--     pre_start   = function(cfg) ... end,       -- run synchronously
--     main        = function(cfg) ... end,       -- spawned as a kernel proc
--     restart     = "on-failure",                -- no | on-failure | always
--     restart_sec = 3,                           -- backoff seconds
--   }
--
-- API:
--   services.discover()             -> list of { name, unit, path }
--   services.start(name)            -> ok, err
--   services.stop(name)             -> ok, err
--   services.restart(name)
--   services.status(name)           -> { state, pid, restarts, last_error }
--   services.list()                 -> array of statuses
--   services.startAll()             -> resolves deps and starts every enabled unit

local log = dofile("/unison/kernel/log.lua")
local role_lib = dofile("/unison/kernel/role.lua")

local M = {}

local UNIT_DIR = "/unison/services.d"

local units = {}            -- name -> unit table
local state = {}            -- name -> { pid, status, restarts, last_error, started_at }
local STATES = {
    INACTIVE = "inactive",
    STARTING = "starting",
    RUNNING  = "running",
    ACTIVE   = "active",     -- pre_start succeeded, no main loop
    EXITED   = "exited",
    FAILED   = "failed",
    STOPPED  = "stopped",
}

local function loadUnit(path)
    local fn, err = loadfile(path)
    if not fn then return nil, "load: " .. tostring(err) end
    local ok, t = pcall(fn)
    if not ok or type(t) ~= "table" then return nil, "unit returned non-table" end
    if not t.name then
        local base = path:match("([^/]+)%.lua$")
        t.name = base
    end
    t.enabled = t.enabled ~= false
    t.restart = t.restart or "no"
    t.restart_sec = t.restart_sec or 3
    t.deps = t.deps or {}
    t.roles = t.roles or { "any" }
    return t
end

function M.discover()
    units = {}
    if not fs.exists(UNIT_DIR) then return {} end
    local out = {}
    for _, f in ipairs(fs.list(UNIT_DIR)) do
        if f:sub(-4) == ".lua" then
            local path = UNIT_DIR .. "/" .. f
            local u, err = loadUnit(path)
            if u then
                units[u.name] = u
                out[#out + 1] = { name = u.name, unit = u, path = path }
            else
                log.warn("services", "skip " .. f .. ": " .. tostring(err))
            end
        end
    end
    return out
end

local function applies(unit, role)
    for _, r in ipairs(unit.roles) do
        if r == "any" or r == role then return true end
    end
    return false
end

local function ensureState(name)
    state[name] = state[name] or {
        pid = nil, status = STATES.INACTIVE,
        restarts = 0, last_error = nil, started_at = nil,
    }
    return state[name]
end

local function spawnSupervised(unit, cfg)
    local sched = unison.kernel.scheduler
    local s = ensureState(unit.name)

    local pid = sched.spawn(function()
        while true do
            s.status = STATES.RUNNING
            s.started_at = os.epoch("utc")
            local ok, err = pcall(unit.main, cfg)
            if not ok then
                s.status = STATES.FAILED
                s.last_error = tostring(err)
                log.error("services", unit.name .. " crashed: " .. tostring(err))
            else
                s.status = STATES.EXITED
                log.info("services", unit.name .. " exited")
            end
            if unit.restart == "no" then return end
            if unit.restart == "on-failure" and ok then return end
            s.restarts = s.restarts + 1
            log.info("services", unit.name .. " respawning in " .. unit.restart_sec .. "s")
            sleep(unit.restart_sec)
        end
    end, unit.name, { group = "system" })

    s.pid = pid
    s.status = STATES.RUNNING
    return pid
end

function M.start(name, cfg)
    local unit = units[name]
    if not unit then return false, "no such unit" end
    if not unit.enabled then return false, "disabled" end
    cfg = cfg or (unison and unison.config) or {}
    local s = ensureState(name)
    if s.status == STATES.RUNNING then return true end

    s.status = STATES.STARTING
    s.last_error = nil

    if unit.pre_start then
        local ok, err = pcall(unit.pre_start, cfg)
        if not ok then
            s.status = STATES.FAILED
            s.last_error = tostring(err)
            log.error("services", name .. " pre_start: " .. tostring(err))
            return false, err
        end
    end

    if unit.main then
        spawnSupervised(unit, cfg)
    else
        -- Oneshot units (no main loop) that completed pre_start are considered
        -- active — they typically registered handlers or spawned background
        -- work elsewhere via the kernel scheduler.
        s.status = STATES.ACTIVE
        s.started_at = os.epoch("utc")
    end
    log.info("services", "started " .. name)
    return true
end

function M.stop(name)
    local s = state[name]
    if not s or not s.pid then
        if state[name] then state[name].status = STATES.STOPPED end
        return true
    end
    local sched = unison.kernel.scheduler
    sched.kill(s.pid)
    s.pid = nil
    s.status = STATES.STOPPED
    log.info("services", "stopped " .. name)
    return true
end

function M.restart(name, cfg)
    M.stop(name)
    sleep(0.2)
    return M.start(name, cfg)
end

function M.status(name)
    return state[name] or { status = STATES.INACTIVE }
end

function M.list()
    local out = {}
    for name, unit in pairs(units) do
        local s = state[name] or { status = STATES.INACTIVE }
        out[#out + 1] = {
            name = name,
            description = unit.description,
            enabled = unit.enabled,
            status = s.status,
            pid = s.pid,
            restarts = s.restarts or 0,
            last_error = s.last_error,
        }
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

local function topoSort(role)
    local order = {}
    local visited = {}
    local visiting = {}

    local function visit(name)
        if visited[name] then return end
        if visiting[name] then
            log.warn("services", "circular dep involving " .. name)
            return
        end
        local u = units[name]
        if not u or not u.enabled or not applies(u, role) then return end
        visiting[name] = true
        for _, dep in ipairs(u.deps) do visit(dep) end
        visiting[name] = nil
        visited[name] = true
        order[#order + 1] = name
    end

    for name in pairs(units) do visit(name) end
    return order
end

function M.startAll(cfg)
    cfg = cfg or (unison and unison.config) or {}
    local role = role_lib.detect(cfg)
    local order = topoSort(role)
    for _, name in ipairs(order) do
        local ok, err = M.start(name, cfg)
        if not ok then
            log.warn("services", "start " .. name .. " failed: " .. tostring(err))
        end
    end
    return order
end

M.STATES = STATES
return M
