-- Display service.
--
-- Discovers attached monitors, builds the multiplex (lib.display.
-- multiplex) so apps see the primary's coordinate system while every
-- term op also lands in a Shadow grid, and periodically flushes that
-- Shadow onto each monitor with delta-rendering (lib.display.monitor).
--
-- The heavy lifting lives in unison/lib/display/{shadow,monitor,
-- multiplex}.lua — this service is the orchestration layer:
-- discovery, persistence, refresh policy, and four worker loops
-- (watcher / periodic / flush / touch).
--
-- Per-monitor settings (enabled, scale, background) are persisted in
-- /unison/state/display.lua; the `displays` shell command edits them.

local log        = dofile("/unison/kernel/log.lua")
local Multiplex  = dofile("/unison/lib/display/multiplex.lua")
local MonRender  = dofile("/unison/lib/display/monitor.lua")

local M = {}

local STATE_FILE = "/unison/state/display.lua"

-- "auto" picks the largest CC scale (0.5..5) where the monitor's
-- cell grid still covers the shadow in BOTH dimensions — minimal
-- letterbox borders, no content clipping. Falls back to 0.5 (most
-- cells) when the monitor is too small to fit the shadow at any scale.
-- Numeric values are honored verbatim; CC rejects <0.5, falls back to 0.5.
local DEFAULT_SCALE = "auto"
local VALID_SCALES = { 5, 4.5, 4, 3.5, 3, 2.5, 2, 1.5, 1, 0.5 }

local function pickAutoScale(mon, shadowW, shadowH)
    if not (mon and mon.setTextScale and mon.getSize) then return 0.5 end
    if not (shadowW and shadowH) then return 0.5 end
    for _, s in ipairs(VALID_SCALES) do
        if pcall(mon.setTextScale, s) then
            local ok, w, h = pcall(mon.getSize)
            if ok and w and h and w >= shadowW and h >= shadowH then
                return s
            end
        end
    end
    return 0.5   -- shadow doesn't fit at any scale → max-cell density
end

local state = {
    primary    = nil,
    monitors   = {},      -- discovered { name, mon } entries
    targets    = {},      -- enabled monitor peripherals
    cfg        = {},
    multiplex  = nil,
    shadow     = nil,
    paintCache = MonRender.newCache(),
    installed  = false,
}

----------------------------------------------------------------------
-- Persistence
----------------------------------------------------------------------

local function readState()
    if not fs.exists(STATE_FILE) then return {} end
    local fn = loadfile(STATE_FILE)
    if not fn then return {} end
    local ok, t = pcall(fn)
    if not (ok and type(t) == "table") then return {} end
    -- Migration: nil scale → "auto" (the new fit-aware default).
    -- Old explicit 0.5 / 1 are preserved so user choices stick.
    if t.monitors then
        for _, s in pairs(t.monitors) do
            if s.scale == nil then s.scale = "auto" end
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

----------------------------------------------------------------------
-- Monitor discovery + per-monitor settings
----------------------------------------------------------------------

local function discoverMonitors()
    local out = {}
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "monitor" then
            out[#out + 1] = { name = name, mon = peripheral.wrap(name) }
        end
    end
    return out
end

local function applyMonitorSettings(entry, settings)
    settings = settings or {}
    if entry.mon.setTextScale then
        local target = settings.scale or DEFAULT_SCALE
        if target == "auto" then
            local sw = state.shadow and state.shadow.w or nil
            local sh = state.shadow and state.shadow.h or nil
            target = pickAutoScale(entry.mon, sw, sh)
        end
        local ok = pcall(entry.mon.setTextScale, target)
        if not ok then pcall(entry.mon.setTextScale, 0.5) end
    end
    -- We deliberately DON'T clear or setBackgroundColor here. The flush
    -- loop owns the framebuffer and re-blits on changed rows; clearing
    -- on every refresh() (which fires from peripheral events and the
    -- periodic safety net) made the monitor blink every ~10 seconds.
end

----------------------------------------------------------------------
-- Build / rebuild the multiplex
----------------------------------------------------------------------

local function rebuild()
    local cfg = state.cfg
    local primary = term.native()
    local enabledMonitors = {}
    local enabledNames = {}
    local primaryMon = nil   -- the monitor flagged as 'primary' in cfg

    for _, mon in ipairs(state.monitors) do
        local mname = mon.name
        local s = (cfg.monitors and cfg.monitors[mname]) or {}
        if s.enabled ~= false then
            applyMonitorSettings(mon, s)
            enabledMonitors[#enabledMonitors + 1] = mon.mon
            enabledNames[#enabledNames + 1] = mname
            if s.primary then primaryMon = mon end
        end
    end

    state.primary = primary
    state.targets = enabledMonitors
    state.targetNames = enabledNames

    -- If a monitor is marked primary, resize the shadow buffer to its
    -- cell grid so the OS draws at the monitor's full resolution. apps'
    -- term.getSize() reports those dimensions, so 79x24 monitors really
    -- get 79x24 of screen — no letterbox, no clipping.
    local muxOpts
    if primaryMon and primaryMon.mon and primaryMon.mon.getSize then
        local ok, mw, mh = pcall(primaryMon.mon.getSize)
        if ok and mw and mh then
            muxOpts = { shadowSize = { w = mw, h = mh } }
        end
    end
    local mux = Multiplex.build(primary, enabledMonitors, muxOpts)
    state.multiplex = mux.multiplex
    state.shadow    = mux.shadow

    -- The set of monitors changed under us — drop any cached frames
    -- so the first flush after a topology change does a full repaint.
    state.paintCache = MonRender.newCache()

    if not state.installed then
        term.redirect(state.multiplex)
        state.installed = true
    else
        term.redirect(state.multiplex)
    end
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

local function defaultConfig(monitors)
    local mc = {}
    for _, mon in ipairs(monitors) do
        mc[mon.name] = { enabled = true, scale = "auto", background = colors.black }
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
                persisted.monitors[mon.name] = { enabled = true, scale = "auto", background = colors.black }
            end
        end
    end
    if cfgOverride and cfgOverride.displays then
        for k, v in pairs(cfgOverride.displays) do persisted[k] = v end
    end
    state.cfg = persisted
    writeState(persisted)
    rebuild()

    log.info("display", "attached " .. #state.monitors ..
        " monitor(s); mirror_all=" .. tostring(persisted.mirror_all))
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
            primary = s.primary == true,
            width = w, height = h,
        }
    end
    return out
end

local function patchCfg(name, key, value)
    local cfg = state.cfg
    cfg.monitors[name] = cfg.monitors[name] or {}
    cfg.monitors[name][key] = value
    writeState(cfg)
    rebuild()
end

function M.setEnabled(name, enabled) patchCfg(name, "enabled", enabled and true or false) end
function M.setScale(name, scale)     patchCfg(name, "scale",   scale) end
function M.setBackground(name, color)patchCfg(name, "background", color) end

-- Mark exactly one monitor as 'primary'. The shadow buffer is then
-- resized to that monitor's cell grid so apps draw at its full
-- resolution. Pass nil / "" to clear (revert to primary terminal sized
-- shadow).
function M.setPrimary(name)
    local cfg = state.cfg
    cfg.monitors = cfg.monitors or {}
    for k, v in pairs(cfg.monitors) do v.primary = nil end
    if name and name ~= "" then
        cfg.monitors[name] = cfg.monitors[name] or {}
        cfg.monitors[name].primary = true
    end
    writeState(cfg)
    rebuild()
end

function M.refresh()
    local fresh = discoverMonitors()
    -- Detect topology change (added or removed monitor by name).
    local prev, now = {}, {}
    for _, m in ipairs(state.monitors or {}) do prev[m.name] = true end
    for _, m in ipairs(fresh) do now[m.name] = true end
    local changed = false
    for k in pairs(prev) do if not now[k] then changed = true; break end end
    if not changed then
        for k in pairs(now) do if not prev[k] then changed = true; break end end
    end

    state.monitors = fresh
    for _, mon in ipairs(state.monitors) do
        if not state.cfg.monitors[mon.name] then
            state.cfg.monitors[mon.name] = { enabled = true, scale = "auto", background = colors.black }
            changed = true
        end
    end
    if changed then
        writeState(state.cfg)
        rebuild()
    end
end

----------------------------------------------------------------------
-- Worker loops (run as kernel coroutines from services.d/display.lua)
----------------------------------------------------------------------

function M.watcherLoop()
    while true do
        local ev, side = os.pullEvent()
        local needRefresh = false
        if ev == "peripheral" or ev == "peripheral_detach" then
            if ev == "peripheral_detach" or peripheral.getType(side) == "monitor" then
                needRefresh = true
            end
        elseif ev == "monitor_resize" then
            needRefresh = true
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

-- Flushes the shadow → every enabled monitor every game tick (50 ms,
-- the CC engine maximum). MonRender.paint does delta-rendering against
-- a per-monitor row cache, so unchanged rows aren't blitted at all.
function M.flushLoop()
    while true do
        sleep(0.05)
        if state.shadow and state.targets then
            for i, mon in ipairs(state.targets) do
                local key = state.targetNames[i] or tostring(i)
                pcall(MonRender.paint, state.shadow, mon, state.paintCache, key)
            end
        end
    end
end

-- Touch input from monitors → mouse_click in primary coords. The
-- letterbox offset from MonRender.touchToShadow gives us the inverse
-- mapping; offscreen taps (on padding) are dropped.
function M.touchLoop()
    while true do
        local _, side, mx, my = os.pullEvent("monitor_touch")
        if state.shadow then
            local mon = peripheral.wrap(side)
            if mon and mon.getSize then
                local ok, mw, mh = pcall(mon.getSize)
                if ok and mw then
                    local sx, sy = MonRender.touchToShadow(state.shadow, mw, mh, mx, my)
                    if sx then
                        os.queueEvent("mouse_click", 1, sx, sy)
                        os.queueEvent("mouse_up",    1, sx, sy)
                    end
                end
            end
        end
    end
end

return M
