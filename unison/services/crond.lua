-- crond — periodic task runner.
--
-- Loads units from /unison/cron.d/<name>.lua. Each unit is a Lua module
-- returning a table:
--   {
--     name           = "fuel-check",
--     description    = "...",
--     enabled        = true,            -- skip if false
--     roles          = { "any" },       -- run only on these roles
--     every_seconds  = 60,              -- fixed interval (seconds), OR
--     cron           = "*/5 * * * *",   -- 5-field cron expression
--                                       --   minute hour day-of-month month day-of-week
--                                       -- supports * , - and /N steps
--     run_at_boot    = false,           -- if true, fire once on startup
--     command        = "rsend 3 ping",  -- a shell command, OR
--     run            = function() ... end,   -- a Lua callback
--   }
--
-- Run state (last_run, runs) is persisted to /unison/state/crond.json so
-- a reboot doesn't replay everything that already fired today.

local log = dofile("/unison/kernel/log.lua")
local role_lib = dofile("/unison/kernel/role.lua")
local fsLib = unison and unison.lib and unison.lib.fs
              or dofile("/unison/lib/fs.lua")

local M = {}

local UNITS_DIR = "/unison/cron.d"
local STATE_FILE = "/unison/state/crond.json"
local TICK = 1   -- second granularity

local units = {}        -- name -> unit
local state = {}        -- name -> { last_run, last_minute, runs, last_error }
local stateDirty = false

-- ---- cron expression parser -----------------------------------------
--
-- Five space-separated fields: minute hour dom month dow.
-- Each field is one of:
--   *           any
--   N           specific value
--   N-M         inclusive range
--   N,M,K       comma list (each part may itself be range)
--   */N         every N starting from low bound
--   M-K/N       every N within range

local function parseField(s, lo, hi)
    s = (s or ""):gsub("%s", "")
    if s == "" then return function() return false end end
    local matchers = {}
    for part in s:gmatch("[^,]+") do
        local body, step = part:match("^(.-)/(%d+)$")
        step = tonumber(step)
        if not step then body = part end
        local a, b
        if body == "*" or body == "" then
            a, b = lo, hi
        elseif body:find("-") then
            local p, q = body:match("^(%d+)-(%d+)$")
            a, b = tonumber(p), tonumber(q)
        else
            a = tonumber(body); b = a
        end
        if a and b then
            local fa, fb, fs = a, b, step or 1
            table.insert(matchers, function(v)
                if v < fa or v > fb then return false end
                return ((v - fa) % fs) == 0
            end)
        end
    end
    return function(v)
        for _, m in ipairs(matchers) do if m(v) then return true end end
        return false
    end
end

local function parseCron(expr)
    local fields = {}
    for f in expr:gmatch("%S+") do fields[#fields + 1] = f end
    if #fields ~= 5 then return nil, "expected 5 fields, got " .. #fields end
    return {
        minute = parseField(fields[1], 0, 59),
        hour   = parseField(fields[2], 0, 23),
        dom    = parseField(fields[3], 1, 31),
        month  = parseField(fields[4], 1, 12),
        dow    = parseField(fields[5], 0, 6),
        expr   = expr,
    }
end

local function nowClock()
    local secs = math.floor(os.epoch("utc") / 1000)
    return os.date("*t", secs)
end

local function epochMinute()
    return math.floor(os.epoch("utc") / 60000)
end

-- ---- state persistence ----------------------------------------------

local function loadState()
    local s = fsLib.readJson(STATE_FILE)
    if type(s) == "table" then state = s end
end

local function saveState()
    if not stateDirty then return end
    pcall(fsLib.writeJson, STATE_FILE, state)
    stateDirty = false
end

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
    if t.cron then
        local parsed, perr = parseCron(t.cron)
        if not parsed then return nil, "bad cron expr: " .. tostring(perr) end
        t._cron = parsed
    end
    if not t.every_seconds and not t._cron then t.every_seconds = 60 end
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
        s = { runs = 0 }
        state[unit.name] = s
        stateDirty = true
        if unit.run_at_boot then return true end
        s.last_run = now
        return false
    end

    -- Cron-expression units: fire at most once per matching minute.
    if unit._cron then
        local minute = epochMinute()
        if s.last_minute == minute then return false end
        local t = nowClock()
        local matches = unit._cron.minute(t.min)
                    and unit._cron.hour(t.hour)
                    and unit._cron.dom(t.day)
                    and unit._cron.month(t.month)
                    and unit._cron.dow((t.wday or 1) - 1)   -- Lua wday=1..7
        return matches
    end

    -- Interval units.
    if not s.last_run then
        if unit.run_at_boot then return true end
        s.last_run = now
        stateDirty = true
        return false
    end
    return (now - s.last_run) >= (unit.every_seconds or 60)
end

local function execute(unit)
    local s = state[unit.name]
    s.last_run = os.epoch("utc") / 1000
    s.last_minute = epochMinute()
    s.runs = (s.runs or 0) + 1
    s.last_error = nil
    stateDirty = true

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
            cron = u.cron,
            command = u.command,
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
    saveState()
    return true
end

local function nameSafe(name)
    return name:match("^[%w%-_]+$") ~= nil
end

local function unitPath(name)
    return UNITS_DIR .. "/" .. name .. ".lua"
end

local function quoteLua(s)
    return string.format("%q", tostring(s or ""))
end

-- Add (or overwrite) a unit and persist it. Reloads in-memory map.
function M.add(opts)
    if type(opts) ~= "table" or not opts.name then
        return false, "name required"
    end
    if not nameSafe(opts.name) then
        return false, "name must be alphanumeric/_/-"
    end
    if opts.cron then
        local _, err = parseCron(opts.cron)
        if err then return false, "bad cron: " .. err end
    elseif not opts.every_seconds then
        return false, "need cron or every_seconds"
    end
    if not (opts.command or opts.run) then
        return false, "need command (Lua callbacks must be added in code)"
    end

    if not fs.exists(UNITS_DIR) then fs.makeDir(UNITS_DIR) end
    local body = "return {\n"
    body = body .. "  name = " .. quoteLua(opts.name) .. ",\n"
    if opts.description then
        body = body .. "  description = " .. quoteLua(opts.description) .. ",\n"
    end
    body = body .. "  enabled = " .. tostring(opts.enabled ~= false) .. ",\n"
    if opts.cron then
        body = body .. "  cron = " .. quoteLua(opts.cron) .. ",\n"
    else
        body = body .. "  every_seconds = " .. tostring(opts.every_seconds) .. ",\n"
    end
    if opts.run_at_boot then
        body = body .. "  run_at_boot = true,\n"
    end
    if opts.command then
        body = body .. "  command = " .. quoteLua(opts.command) .. ",\n"
    end
    if opts.roles then
        body = body .. "  roles = { "
        for _, r in ipairs(opts.roles) do body = body .. quoteLua(r) .. ", " end
        body = body .. "},\n"
    end
    body = body .. "}\n"

    local h = fs.open(unitPath(opts.name), "w")
    if not h then return false, "cannot open file" end
    h.write(body); h.close()

    M.discover()
    return true
end

function M.remove(name)
    if not name or not nameSafe(name) then return false, "bad name" end
    local p = unitPath(name)
    if fs.exists(p) then fs.delete(p) end
    state[name] = nil
    stateDirty = true
    saveState()
    units[name] = nil
    return true
end

function M.setEnabled(name, enabled)
    local u = units[name]
    if not u then return false, "no such unit" end
    return M.add({
        name = name,
        description = u.description,
        cron = u.cron,
        every_seconds = u.every_seconds,
        command = u.command,
        roles = u.roles,
        run_at_boot = u.run_at_boot,
        enabled = enabled and true or false,
    })
end

-- Returns the parsed cron table for diagnostics.
function M.parseCronExpr(expr)
    return parseCron(expr)
end

function M.loop()
    loadState()
    M.discover()
    local n = 0; for _ in pairs(units) do n = n + 1 end
    log.info("crond", "loaded " .. n .. " unit(s)")
    local saveEvery = 30
    local saveTimer = 0
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
        saveTimer = saveTimer + TICK
        if saveTimer >= saveEvery then saveState(); saveTimer = 0 end
    end
end

return M
