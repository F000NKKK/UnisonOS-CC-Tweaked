-- Display manager.
--
-- Discovers attached monitors and mirrors the local terminal output to all
-- enabled targets (the on-device screen plus every enabled monitor), like
-- multiple displays on a desktop PC. Per-monitor settings (enabled, scale,
-- background) are persisted in /unison/state/display.lua and can be edited
-- via the `displays` shell command.

local log = dofile("/unison/kernel/log.lua")

local M = {}

local STATE_FILE = "/unison/state/display.lua"

local TERM_FORWARD = {
    "write", "blit", "clear", "clearLine",
    "setCursorPos", "setCursorBlink",
    "setTextColor", "setTextColour",
    "setBackgroundColor", "setBackgroundColour",
    "scroll",
    "setPaletteColor", "setPaletteColour",
}

local TERM_QUERY_PRIMARY = {
    "getCursorPos", "getCursorBlink",
    "getTextColor", "getTextColour",
    "getBackgroundColor", "getBackgroundColour",
    "isColor", "isColour",
    "getPaletteColor", "getPaletteColour",
    "getSize",
}

local state = {
    primary = nil,
    targets = {},
    monitors = {},
    cfg = {},
    multiplex = nil,
    installed = false,
}

local function readState()
    if not fs.exists(STATE_FILE) then return {} end
    local fn = loadfile(STATE_FILE)
    if not fn then return {} end
    local ok, t = pcall(fn)
    if not (ok and type(t) == "table") then return {} end
    -- Migration: anything still pinned at scale=1 was the old default
    -- before we made 0.5 (max area, smallest text) the new default.
    -- Bump it so existing monitors switch over without manual config.
    if t.monitors then
        for _, s in pairs(t.monitors) do
            if s.scale == 1 or s.scale == nil then s.scale = 0.5 end
        end
    end
    return t
end

local function writeState(t)
    if not fs.exists("/unison/state") then fs.makeDir("/unison/state") end
    local h = fs.open(STATE_FILE, "w")
    h.write("return " .. textutils.serialize(t))
    h.close()
end

local function discoverMonitors()
    local out = {}
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "monitor" then
            out[#out + 1] = { name = name, mon = peripheral.wrap(name) }
        end
    end
    return out
end

local DEFAULT_SCALE = 0.5

local function applyMonitorSettings(entry, settings)
    settings = settings or {}
    if entry.mon.setTextScale then
        pcall(entry.mon.setTextScale, settings.scale or DEFAULT_SCALE)
    end
    if entry.mon.setBackgroundColor then
        pcall(entry.mon.setBackgroundColor, settings.background or colors.black)
    end
    if entry.mon.clear then pcall(entry.mon.clear) end
    if entry.mon.setCursorPos then pcall(entry.mon.setCursorPos, 1, 1) end
end

local function buildMultiplex(primary, targets)
    local m = {}
    local failures = {}    -- target -> consecutive failure count

    for _, fn in ipairs(TERM_FORWARD) do
        m[fn] = function(...)
            local args = { ... }
            local stale = false
            for _, t in ipairs(targets) do
                if t[fn] then
                    local ok = pcall(t[fn], table.unpack(args))
                    if not ok then
                        failures[t] = (failures[t] or 0) + 1
                        if failures[t] > 5 then stale = true end
                    else
                        failures[t] = 0
                    end
                end
            end
            -- If anything looked stale, ask the watcher to re-scan.
            if stale then os.queueEvent("peripheral_detach", "monitor") end
        end
    end

    for _, fn in ipairs(TERM_QUERY_PRIMARY) do
        m[fn] = function(...)
            if primary[fn] then return primary[fn](...) end
        end
    end

    m.redirect = function(target) return target end

    return m
end

local function rebuild()
    local cfg = state.cfg
    local primary = term.native()
    local targets = { primary }

    for _, mon in ipairs(state.monitors) do
        local mname = mon.name
        local s = (cfg.monitors and cfg.monitors[mname]) or {}
        if s.enabled ~= false then
            applyMonitorSettings(mon, s)
            targets[#targets + 1] = mon.mon
        end
    end

    state.primary = primary
    state.targets = targets
    state.multiplex = buildMultiplex(primary, targets)

    if not state.installed then
        term.redirect(state.multiplex)
        state.installed = true
    else
        term.redirect(state.multiplex)
    end
end

local function defaultConfig(monitors)
    local mc = {}
    for _, mon in ipairs(monitors) do
        mc[mon.name] = { enabled = true, scale = 0.5, background = colors.black }
    end
    return { mirror_all = true, monitors = mc }
end

function M.start(cfgOverride)
    state.monitors = discoverMonitors()
    local persisted = readState()
    if not persisted.monitors then
        persisted = defaultConfig(state.monitors)
    else
        for _, mon in ipairs(state.monitors) do
            if not persisted.monitors[mon.name] then
                persisted.monitors[mon.name] = { enabled = true, scale = 0.5, background = colors.black }
            end
        end
    end
    if cfgOverride and cfgOverride.displays then
        for k, v in pairs(cfgOverride.displays) do persisted[k] = v end
    end
    state.cfg = persisted
    writeState(persisted)
    rebuild()

    log.info("display", "attached " .. #state.monitors .. " monitor(s); mirror_all=" .. tostring(persisted.mirror_all))
end

function M.list()
    local out = {}
    for _, mon in ipairs(state.monitors) do
        local s = state.cfg.monitors[mon.name] or {}
        local w, h = -1, -1
        if mon.mon.getSize then
            local ok, ww, hh = pcall(mon.mon.getSize)
            if ok then w, h = ww, hh end
        end
        out[#out + 1] = {
            name = mon.name,
            enabled = s.enabled ~= false,
            scale = s.scale or 1,
            width = w,
            height = h,
        }
    end
    return out
end

function M.setEnabled(name, enabled)
    local cfg = state.cfg
    cfg.monitors[name] = cfg.monitors[name] or {}
    cfg.monitors[name].enabled = enabled and true or false
    writeState(cfg)
    rebuild()
end

function M.setScale(name, scale)
    local cfg = state.cfg
    cfg.monitors[name] = cfg.monitors[name] or {}
    cfg.monitors[name].scale = scale
    writeState(cfg)
    rebuild()
end

function M.setBackground(name, color)
    local cfg = state.cfg
    cfg.monitors[name] = cfg.monitors[name] or {}
    cfg.monitors[name].background = color
    writeState(cfg)
    rebuild()
end

function M.refresh()
    state.monitors = discoverMonitors()
    for _, mon in ipairs(state.monitors) do
        if not state.cfg.monitors[mon.name] then
            state.cfg.monitors[mon.name] = { enabled = true, scale = 0.5, background = colors.black }
        end
    end
    writeState(state.cfg)
    rebuild()
end

function M.watcherLoop()
    -- Periodic safety net: re-discover monitors every ~10s in case an
    -- attach/detach event was missed (occasional CC quirk on
    -- monitor reconnects).
    local function tick()
        os.startTimer(10)
        return os.pullEvent()
    end
    while true do
        local ev, side = os.pullEvent()
        local needRefresh = false
        if ev == "peripheral" or ev == "peripheral_detach" then
            if ev == "peripheral_detach" or peripheral.getType(side) == "monitor" then
                needRefresh = true
            end
        elseif ev == "monitor_resize" then
            needRefresh = true
        elseif ev == "timer" then
            -- ignore — only used for periodic refresh by spawnPeriodic
        end
        if needRefresh then
            local prev = #state.monitors
            M.refresh()
            if prev ~= #state.monitors then
                log.info("display", "monitor topology changed; targets=" .. #state.targets)
            end
        end
    end
end

function M.periodicRefreshLoop()
    while true do
        sleep(10)
        local prev = #state.monitors
        local ok = pcall(M.refresh)
        if ok and prev ~= #state.monitors then
            log.info("display", "periodic refresh saw " .. #state.monitors .. " monitor(s)")
        end
    end
end

return M
