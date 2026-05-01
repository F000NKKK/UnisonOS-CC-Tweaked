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

-- We default to the smallest scale CC supports for max cell count. CC
-- rejects values below 0.5 with an error, so applyMonitorSettings tries
-- the requested value first and falls back to 0.5 if the engine refuses.
local DEFAULT_SCALE = 0.1

local function applyMonitorSettings(entry, settings)
    settings = settings or {}
    if entry.mon.setTextScale then
        local target = settings.scale or DEFAULT_SCALE
        local ok = pcall(entry.mon.setTextScale, target)
        if not ok then pcall(entry.mon.setTextScale, 0.5) end
    end
    if entry.mon.setBackgroundColor then
        pcall(entry.mon.setBackgroundColor, settings.background or colors.black)
    end
    if entry.mon.clear then pcall(entry.mon.clear) end
    if entry.mon.setCursorPos then pcall(entry.mon.setCursorPos, 1, 1) end
end

----------------------------------------------------------------------
-- Shadow buffer + monitor scaling
--
-- Apps target the primary terminal's coordinate system (multiplex.getSize
-- returns primary's dimensions). Every forwarded write/blit/setCursorPos
-- mutates BOTH the primary AND a per-cell shadow grid sized to primary.
-- A periodic flusher paints the shadow onto each monitor by mapping
-- monitor cells to shadow cells with nearest-neighbor scaling — so a
-- big monitor stretches the content, a small one shrinks it, but no
-- coordinates ever fall off-screen.
----------------------------------------------------------------------

local HEX = {
    [colors.white]      = "0", [colors.orange]    = "1",
    [colors.magenta]    = "2", [colors.lightBlue] = "3",
    [colors.yellow]     = "4", [colors.lime]      = "5",
    [colors.pink]       = "6", [colors.gray]      = "7",
    [colors.lightGray]  = "8", [colors.cyan]      = "9",
    [colors.purple]     = "a", [colors.blue]      = "b",
    [colors.brown]      = "c", [colors.green]     = "d",
    [colors.red]        = "e", [colors.black]     = "f",
}

local function newShadow(w, h)
    local cells = {}
    for y = 1, h do
        cells[y] = {}
        for x = 1, w do
            cells[y][x] = { ch = " ", fg = colors.white, bg = colors.black }
        end
    end
    return {
        w = w, h = h, cells = cells,
        cx = 1, cy = 1, fg = colors.white, bg = colors.black,
    }
end

local function shadowSet(sh, x, y, ch, fg, bg)
    if y < 1 or y > sh.h or x < 1 or x > sh.w then return end
    local row = sh.cells[y]; if not row then return end
    local cell = row[x]
    cell.ch = ch; cell.fg = fg; cell.bg = bg
end

local function shadowWrite(sh, s)
    s = tostring(s or "")
    for i = 1, #s do
        shadowSet(sh, sh.cx + i - 1, sh.cy, s:sub(i, i), sh.fg, sh.bg)
    end
    sh.cx = sh.cx + #s
end

local function shadowBlit(sh, text, fgs, bgs)
    for i = 1, #text do
        local f = tonumber(fgs:sub(i, i), 16) or 0
        local b = tonumber(bgs:sub(i, i), 16) or 15
        shadowSet(sh, sh.cx + i - 1, sh.cy, text:sub(i, i), 2 ^ f, 2 ^ b)
    end
    sh.cx = sh.cx + #text
end

local function shadowClear(sh)
    for y = 1, sh.h do
        for x = 1, sh.w do
            shadowSet(sh, x, y, " ", sh.fg, sh.bg)
        end
    end
end

local function shadowClearLine(sh)
    if sh.cy < 1 or sh.cy > sh.h then return end
    for x = 1, sh.w do shadowSet(sh, x, sh.cy, " ", sh.fg, sh.bg) end
end

local function shadowScroll(sh, n)
    n = tonumber(n) or 0
    if n == 0 then return end
    if n > 0 then
        for y = 1, sh.h do
            local src = y + n
            if src <= sh.h then sh.cells[y] = sh.cells[src]
            else
                sh.cells[y] = {}
                for x = 1, sh.w do
                    sh.cells[y][x] = { ch = " ", fg = sh.fg, bg = sh.bg }
                end
            end
        end
    else
        for y = sh.h, 1, -1 do
            local src = y + n
            if src >= 1 then sh.cells[y] = sh.cells[src]
            else
                sh.cells[y] = {}
                for x = 1, sh.w do
                    sh.cells[y][x] = { ch = " ", fg = sh.fg, bg = sh.bg }
                end
            end
        end
    end
end

-- Paint shadow → monitor by CENTERED LETTERBOX. Nearest-neighbor cell
-- scaling distorts text because characters get duplicated/dropped at
-- non-integer ratios — "0.17.0" becomes "0.177.0" on a wider monitor.
-- Instead we paint the primary grid at its native size, centred in the
-- monitor with empty padding around it. Bigger monitors letterbox;
-- smaller monitors crop. Text stays crisp.
local function paintMonitor(sh, mon)
    local ok, mw, mh = pcall(mon.getSize)
    if not ok or not mw or mw < 1 or mh < 1 then return false end

    -- Top-left corner of primary's grid in monitor cell space.
    local offX = math.floor((mw - sh.w) / 2)
    local offY = math.floor((mh - sh.h) / 2)

    -- Clear monitor background once per frame so the letterbox padding
    -- isn't stale content from a previous (larger) frame.
    pcall(mon.setBackgroundColor, colors.black)
    pcall(mon.clear)

    for sy = 1, sh.h do
        local my = sy + offY
        if my >= 1 and my <= mh then
            local row = sh.cells[sy]

            -- Visible source range in shadow coords: [sx0..sx1] maps to
            -- [mx0..mx1] in monitor coords.
            local sx0 = 1
            local mx0 = offX + 1
            if mx0 < 1 then sx0 = 1 - offX; mx0 = 1 end
            local sx1 = sh.w
            if mx0 + (sx1 - sx0) > mw then sx1 = sx0 + (mw - mx0) end

            if sx1 >= sx0 then
                local chars, fgs, bgs = {}, {}, {}
                for sx = sx0, sx1 do
                    local cell = row[sx]
                    chars[#chars + 1] = cell.ch
                    fgs[#fgs + 1] = HEX[cell.fg] or "0"
                    bgs[#bgs + 1] = HEX[cell.bg] or "f"
                end
                pcall(mon.setCursorPos, mx0, my)
                pcall(mon.blit,
                    table.concat(chars), table.concat(fgs), table.concat(bgs))
            end
        end
    end
    return true
end

local function buildMultiplex(primary, monitors)
    local m = {}
    local pw, ph = primary.getSize()
    local shadow = newShadow(pw, ph)
    local dirty = false
    state.shadow = shadow

    -- Cursor / colour bookkeeping on the shadow.
    local function syncCursor()
        local ok, x, y = pcall(primary.getCursorPos)
        if ok then shadow.cx = x; shadow.cy = y end
    end
    syncCursor()
    shadow.fg = primary.getTextColor and primary.getTextColor() or colors.white
    shadow.bg = primary.getBackgroundColor and primary.getBackgroundColor() or colors.black

    function m.write(s)
        shadowWrite(shadow, s); pcall(primary.write, s); dirty = true
    end
    function m.blit(text, fgs, bgs)
        shadowBlit(shadow, text, fgs, bgs)
        pcall(primary.blit, text, fgs, bgs); dirty = true
    end
    function m.clear()
        shadowClear(shadow); pcall(primary.clear); dirty = true
    end
    function m.clearLine()
        shadowClearLine(shadow); pcall(primary.clearLine); dirty = true
    end
    function m.setCursorPos(x, y)
        shadow.cx = x; shadow.cy = y
        pcall(primary.setCursorPos, x, y)
    end
    function m.scroll(n)
        shadowScroll(shadow, n); pcall(primary.scroll, n); dirty = true
    end
    function m.setTextColor(c)     shadow.fg = c; pcall(primary.setTextColor, c) end
    m.setTextColour = m.setTextColor
    function m.setBackgroundColor(c) shadow.bg = c; pcall(primary.setBackgroundColor, c) end
    m.setBackgroundColour = m.setBackgroundColor
    function m.setCursorBlink(b)   pcall(primary.setCursorBlink, b) end
    function m.setPaletteColor(...)
        pcall(primary.setPaletteColor, ...)
        for _, mon in ipairs(monitors) do pcall(mon.setPaletteColor, ...) end
    end
    m.setPaletteColour = m.setPaletteColor

    for _, fn in ipairs(TERM_QUERY_PRIMARY) do
        m[fn] = function(...) if primary[fn] then return primary[fn](...) end end
    end
    m.redirect = function(target) return target end

    -- Public hook: flush shadow → all monitors. Called periodically.
    -- We paint EVERY tick — not conditional on `dirty` — because other
    -- code paths (peripheral attach/detach, gps-host bootstrap, displays
    -- shell command, manual mon.clear() from elsewhere) can wipe the
    -- monitor's framebuffer underneath us. A blind re-paint is the
    -- simplest correctness guarantee; the cost is one blit-per-row at
    -- 10 Hz which CC handles fine.
    state.flushMonitors = function()
        for _, mon in ipairs(monitors) do paintMonitor(shadow, mon) end
        dirty = false
    end

    return m
end

local function rebuild()
    local cfg = state.cfg
    local primary = term.native()
    local enabledMonitors = {}

    for _, mon in ipairs(state.monitors) do
        local mname = mon.name
        local s = (cfg.monitors and cfg.monitors[mname]) or {}
        if s.enabled ~= false then
            applyMonitorSettings(mon, s)
            enabledMonitors[#enabledMonitors + 1] = mon.mon
        end
    end

    state.primary = primary
    state.targets = enabledMonitors
    state.multiplex = buildMultiplex(primary, enabledMonitors)
    state.forceFlush = true

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

-- Monitor flush loop: paints the shadow buffer onto every attached
-- monitor every game tick (50 ms — engine maximum). Each frame: clear
-- the monitor and re-blit the shadow. Letterbox-centered.
function M.flushLoop()
    while true do
        sleep(0.05)              -- ~20 Hz; CC ticks at 20 TPS, can't go faster
        if state.flushMonitors then
            pcall(state.flushMonitors)
        end
    end
end

-- Monitor touch loop: CC emits `monitor_touch <side> <x> <y>` when a
-- player clicks on a monitor. We translate the monitor cell coords back
-- to primary terminal coords (reversing the letterbox offset) and queue
-- an equivalent `mouse_click` event so apps that already handle mouse
-- events Just Work — including the desktop launcher.
function M.touchLoop()
    while true do
        local _, side, mx, my = os.pullEvent("monitor_touch")
        local sh = state.shadow; if not sh then goto continue end
        -- Find this monitor in our enabled list to read its size.
        local mon = peripheral.wrap(side)
        if not mon or not mon.getSize then goto continue end
        local ok, mw, mh = pcall(mon.getSize)
        if not ok or not mw then goto continue end
        local offX = math.floor((mw - sh.w) / 2)
        local offY = math.floor((mh - sh.h) / 2)
        local sx = mx - offX
        local sy = my - offY
        if sx >= 1 and sx <= sh.w and sy >= 1 and sy <= sh.h then
            -- Synthesise a left-click at the corresponding primary cell.
            os.queueEvent("mouse_click", 1, sx, sy)
            os.queueEvent("mouse_up", 1, sx, sy)
        end
        ::continue::
    end
end

return M
