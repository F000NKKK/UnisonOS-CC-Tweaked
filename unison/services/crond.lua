-- crond — periodic task runner.
--
-- Loads units from /unison/cron.d/<name>.lua. Each unit is a Lua module
-- returning a table:
--   {
--     name           = "fuel-check",
--     description    = "...",
--     enabled        = true,            -- skip if false
--     roles          = { "any" },       -- run only on these roles
--     every_seconds  = 60,              -- fixed interval (seconds)
--     run_at_boot    = false,           -- if true, fire once on startup
--     command        = "rsend 3 ping",  -- a shell command, OR
--     run            = function() ... end,   -- a Lua callback
--   }

local log = dofile("/unison/kernel/log.lua")
local role_lib = dofile("/unison/kernel/role.lua")

local M = {}

local UNITS_DIR = "/unison/cron.d"
local TICK = 1   -- second granularity

local units = {}        -- name -> unit
local state = {}        -- name -> { last_run, runs, last_error }

local function loadUnit(path)
    local fn, err = loadfile(path)
    if not fn then return nil, err end
    local ok, t = pcall(fn)
    if not ok or type(t) ~= "table" then return nil, "non-table" end
    if not t.name then
        local base = path:match("([^/]+)%.lua$")
        t.name = base
    end
    if t.enabled == nil then t.enabled = true end
    if not t.every_seconds and not t.cron then t.every_seconds = 60 end
    return t
end

function M.discover()
    units = {}
    if not fs.exists(UNITS_DIR) then return {} end
    for _, f in ipairs(fs.list(UNITS_DIR)) do
        if f:sub(-4) == ".lua" then
            local u, err = loadUnit(UNITS_DIR .. "/" .. f)
            if u then
                units[u.name] = u
            else
                log.warn("crond", "skip " .. f .. ": " .. tostring(err))
            end
        end
    end
    return units
end

local function shouldRun(unit, role, now)
    if not unit.enabled then return false end
    if unit.roles then
        local ok = false
        for _, r in ipairs(unit.roles) do
            if r == "any" or r == role then ok = true; break end
        end
        if not ok then return false end
    end
    local s = state[unit.name]
    if not s then
        state[unit.name] = { last_run = nil, runs = 0 }
        if unit.run_at_boot then return true end
        state[unit.name].last_run = now   -- avoid first-tick rush
        return false
    end
    if not s.last_run then
        if unit.run_at_boot then return true end
        s.last_run = now
        return false
    end
    return (now - s.last_run) >= (unit.every_seconds or 60)
end

local function execute(unit)
    local s = state[unit.name]
    s.last_run = os.epoch("utc") / 1000
    s.runs = (s.runs or 0) + 1
    s.last_error = nil

    local ok, err
    if type(unit.run) == "function" then
        ok, err = pcall(unit.run)
    elseif type(unit.command) == "string" then
        if shell and shell.run then
            ok, err = pcall(shell.run, unit.command)
        else
            -- fallback: load and run as a shell line via the run command
            ok, err = false, "no shell available"
        end
    else
        ok, err = false, "unit has no run/command"
    end

    if not ok then
        s.last_error = tostring(err)
        log.warn("crond", "unit " .. unit.name .. " failed: " .. tostring(err))
    else
        log.debug("crond", "ran " .. unit.name)
    end
end

function M.list()
    local out = {}
    for name, u in pairs(units) do
        local s = state[name] or {}
        out[#out + 1] = {
            name = name,
            description = u.description,
            enabled = u.enabled,
            every_seconds = u.every_seconds,
            runs = s.runs or 0,
            last_run = s.last_run,
            last_error = s.last_error,
        }
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

function M.runOnce(name)
    local u = units[name]
    if not u then return false, "no such unit" end
    state[name] = state[name] or { runs = 0 }
    execute(u)
    return true
end

function M.loop()
    M.discover()
    log.info("crond", "loaded " .. (function() local n = 0; for _ in pairs(units) do n = n + 1 end; return n end)() .. " unit(s)")
    while true do
        local now = os.epoch("utc") / 1000
        local role = role_lib.detect(unison and unison.config or {})
        for _, unit in pairs(units) do
            if shouldRun(unit, role, now) then
                local ok, err = pcall(execute, unit)
                if not ok then
                    log.warn("crond", "execute crash for " .. unit.name .. ": " .. tostring(err))
                end
            end
        end
        sleep(TICK)
    end
end

return M
