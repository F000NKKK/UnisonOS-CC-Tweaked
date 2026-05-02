-- unison.ui.desktop — TUI shell with hand-drawn pixel chrome.
--
-- Chrome (top bar, bottom bar, launcher icons) is rendered via
-- canvas.subpixel — each cell holds two stacked pixels via the
-- half-block character, doubling vertical resolution.
--
-- Layout:
--   Row 1     : pixel top bar (logo on left, title in middle, time right)
--   Rows 2..  : workspace (apps) on the left + launcher panel on the right
--   Row H     : pixel bottom bar with hint text
--
-- Keys (no Ctrl combos — CC doesn't surface modifier state):
--   Tab           cycle focus
--   1..9          fast-launch app N
--   Up/Dn/Enter   navigate launcher
--   x             close focused app (from launcher)
--   q             quit desktop (from launcher)

local wm     = dofile("/unison/ui/wm.lua")
local Buffer = dofile("/unison/ui/buffer.lua")
local canvas = dofile("/unison/lib/canvas.lua")

local M = {}
local APPS_DIR = "/unison/ui/apps"

----------------------------------------------------------------------
-- App discovery
----------------------------------------------------------------------

local function loadApp(file)
    local p = APPS_DIR .. "/" .. file
    local fn, err = loadfile(p)
    if not fn then return nil, err end
    local ok, mod = pcall(fn)
    if not ok or type(mod) ~= "table" then return nil, "not a module" end
    if not mod.id   then mod.id = file:gsub("%.lua$", "") end
    if not mod.title then mod.title = mod.id end
    return mod
end

local function discoverApps()
    local out = {}
    if not fs.exists(APPS_DIR) then return out end
    for _, f in ipairs(fs.list(APPS_DIR)) do
        if f:sub(-4) == ".lua" then
            local mod = loadApp(f)
            if mod then out[#out + 1] = mod end
        end
    end
    table.sort(out, function(a, b) return (a.title or "") < (b.title or "") end)
    return out
end

local function appAllowedHere(app, role)
    if not app.roles or #app.roles == 0 then return true end
    for _, r in ipairs(app.roles) do
        if r == "any" or r == role then return true end
    end
    return false
end

----------------------------------------------------------------------
-- Pixel art helpers
----------------------------------------------------------------------

-- 16-color palette to pick from (skip black so icons stay visible).
local ICON_PALETTE = {
    colors.lightBlue, colors.lime, colors.orange, colors.magenta,
    colors.yellow, colors.cyan, colors.pink, colors.purple,
    colors.red, colors.green, colors.brown,
}

local function iconColor(id)
    local h = 0
    for i = 1, #id do h = (h * 31 + id:byte(i)) % 1000003 end
    return ICON_PALETTE[(h % #ICON_PALETTE) + 1]
end

-- Smooth gradient across N stops, returns the colour for index i in [1..n].
-- Picks from a palette so each band is a discrete CC colour.
local function gradient(palette, n, i)
    local p = math.max(1, math.min(#palette, math.ceil((i / n) * #palette)))
    return palette[p]
end

-- Draws a 2-pixel-tall horizontal strip on cell row `cy`, with the
-- per-x top/bottom colours coming from the colour-fn(x).
-- The render writes one half-block character per cell with fg=top, bg=bot.
local fmt = dofile("/unison/lib/fmt.lua")
local HEX = fmt.HEX
local HALF_BLOCK = fmt.HALF_BLOCK

local function drawStrip(cy, w, colourFn)
    local t = term.current()
    local chars, fgs, bgs = {}, {}, {}
    for x = 1, w do
        local top, bot = colourFn(x)
        chars[#chars + 1] = HALF_BLOCK
        fgs[#fgs + 1] = HEX[top or colors.gray] or "7"
        bgs[#bgs + 1] = HEX[bot or colors.gray] or "7"
    end
    t.setCursorPos(1, cy)
    t.blit(table.concat(chars), table.concat(fgs), table.concat(bgs))
end

-- Overlays plain text on top of the strip we just drew. Writing text
-- replaces the half-block in those cells, but we keep the bg colour
-- so it visually reads as part of the strip.
local function overlayText(t, cx, cy, str, fg, bg)
    t.setCursorPos(cx, cy)
    t.setTextColor(fg)
    t.setBackgroundColor(bg)
    t.write(str)
end

----------------------------------------------------------------------
-- Chrome
----------------------------------------------------------------------

-- Top bar: gradient cyan→blue strip, "UnisonOS" wordmark on left,
-- focused app title in the middle, clock on the right.
local function drawTopBar(state)
    local W = state.W
    local TOP_PAL = { colors.cyan, colors.lightBlue, colors.blue, colors.gray }
    local BOT_PAL = { colors.lightBlue, colors.blue, colors.gray, colors.gray }

    drawStrip(1, W, function(x)
        return gradient(TOP_PAL, W, x), gradient(BOT_PAL, W, x)
    end)

    local t = term.current()
    -- Wordmark.
    local node = (unison and unison.node) or "?"
    local role = (unison and unison.role) or "?"
    local left = string.format(" UnisonOS  %s/%s ", node, role)
    overlayText(t, 1, 1, left, colors.white, colors.cyan)

    -- Focused app pill in the middle.
    local f = wm.focused()
    if f and f.title and f.id ~= "desk:launcher" then
        local pill = " " .. f.title .. " "
        local cx = math.max(#left + 2, math.floor((W - #pill) / 2))
        overlayText(t, cx, 1, pill, colors.black, colors.yellow)
    end

    -- Clock right.
    local time = " " .. textutils.formatTime(os.time(), false) .. " "
    overlayText(t, W - #time + 1, 1, time, colors.white, colors.gray)
end

local function drawBottomBar(state)
    local W, H = state.W, state.H
    -- Two-tone strip: light grey top, darker grey bottom.
    drawStrip(H, W, function(x)
        local t = (x % 6 < 3) and colors.lightGray or colors.gray
        local b = colors.gray
        return t, b
    end)
    local t = term.current()
    local hint = " Tab cycle | 1-9 fast-launch | Up/Dn Enter | x close | q quit "
    if #hint > W then hint = hint:sub(1, W) end
    overlayText(t, 1, H, hint, colors.black, colors.lightGray)
end

----------------------------------------------------------------------
-- Launcher (right-hand strip, drawn directly — not a WM window).
-- Each entry is one cell tall: 1-cell pixel-art icon + label.
----------------------------------------------------------------------

local LAUNCHER_W = 22

local function drawLauncher(state, sel)
    local W, H = state.W, state.H
    local lx = W - LAUNCHER_W + 1
    local ly = 2
    local lh = H - 2
    local t = term.current()

    -- Background panel (cells).
    for row = 0, lh - 1 do
        t.setCursorPos(lx, ly + row)
        t.setBackgroundColor(colors.black)
        t.write(string.rep(" ", LAUNCHER_W))
    end

    -- Header with cyan accent strip drawn as 1-cell pixel band.
    drawStrip(ly, LAUNCHER_W, function(x)
        local pos = ((x - 1) % 5)
        local fg = (pos < 2) and colors.cyan or colors.lightBlue
        return fg, colors.gray
    end)
    overlayText(t, lx, ly, " Apps", colors.white, colors.cyan)

    -- Entries.
    for i, app in ipairs(state.apps) do
        local row = ly + 1 + i
        if row >= ly + lh - 1 then break end
        local selected = (i == sel)
        local rowBg = selected and colors.yellow or colors.black
        local rowFg = selected and colors.black or colors.white

        -- Icon: 1 cell painted as a 2-pixel coloured tile via half-block.
        -- We give it a "shaded" feel: top half = base colour, bottom half = darker.
        local hue = iconColor(app.id or app.title)
        t.setCursorPos(lx + 1, row)
        t.blit(HALF_BLOCK, HEX[hue] or "0", HEX[colors.gray] or "7")

        -- Number + title.
        local label = string.format(" %d %s", i, app.title or app.id)
        if #label > LAUNCHER_W - 4 then label = label:sub(1, LAUNCHER_W - 4) end
        local pad = LAUNCHER_W - 3 - #label
        overlayText(t, lx + 2, row, label .. string.rep(" ", math.max(0, pad)),
            rowFg, rowBg)
    end

    -- Footer hint inside launcher.
    overlayText(t, lx, ly + lh - 1,
        string.rep(" ", LAUNCHER_W - 1):sub(1, LAUNCHER_W),
        colors.lightGray, colors.gray)
    overlayText(t, lx, ly + lh - 1, " 1-9 quick  Enter open ",
        colors.black, colors.gray)
end

----------------------------------------------------------------------
-- Run loop
----------------------------------------------------------------------

function M.run(opts)
    opts = opts or {}
    local W, H = term.getSize()
    local role = (unison and unison.role) or "any"

    local apps = {}
    for _, a in ipairs(discoverApps()) do
        if appAllowedHere(a, role) then apps[#apps + 1] = a end
    end

    local state = {
        W = W, H = H, apps = apps,
        openWindows = {}, running = true,
        sel = 1,
        focusOnLauncher = true,
    }

    local function openApp(app)
        if not (app and app.make) then return end
        local existing = state.openWindows[app.id]
        if existing and existing.visible then
            wm.focus(existing); state.focusOnLauncher = false; return
        end
        -- App workspace = everything left of the launcher, between top and bottom bars.
        local win = app.make({
            x = 1, y = 2, w = W - LAUNCHER_W, h = H - 2,
        })
        win.title = win.title or app.title or app.id
        state.openWindows[app.id] = win
        wm.add(win); wm.focus(win)
        state.focusOnLauncher = false
    end

    local function closeFocused()
        local f = wm.focused()
        if not f then return end
        for id, w in pairs(state.openWindows) do
            if w == f then state.openWindows[id] = nil; break end
        end
        wm.remove(f)
        state.focusOnLauncher = true
    end

    local function quitDesktop() state.running = false end

    -- Detect clicks on the launcher. Returns app index (1..N) or nil.
    local function launcherClickToApp(mx, my)
        local lx = state.W - LAUNCHER_W + 1
        if mx < lx or mx > state.W then return nil end
        if my < 3 then return nil end       -- header row at ly=2; entries from ly+1+i
        if my >= state.H then return nil end
        -- Entry rows: my = 2 + 1 + i  →  i = my - 3
        local i = my - 3
        if i >= 1 and i <= #state.apps then return i end
        return nil
    end

    -- Input handler that's NOT a WM window (so we draw the launcher
    -- directly, but route keys/clicks based on focus state).
    local function handleKey(ev)
        local kind = ev[1]

        -- Mouse: clicks on the launcher always work, regardless of focus.
        if kind == "mouse_click" or kind == "mouse_up" then
            local mx, my = ev[3], ev[4]
            local appIdx = launcherClickToApp(mx, my)
            if appIdx then
                if kind == "mouse_click" then
                    state.sel = appIdx
                    openApp(state.apps[appIdx])
                end
                return
            end
            -- Click outside launcher → app workspace; forward to focused win.
            if not state.focusOnLauncher then
                local f = wm.focused()
                if f and f.onEvent then pcall(f.onEvent, f, ev) end
            end
            return
        end

        if state.focusOnLauncher then
            if kind == "key" then
                local k = ev[2]
                if k == keys.up   and state.sel > 1                then state.sel = state.sel - 1 end
                if k == keys.down and state.sel < #state.apps      then state.sel = state.sel + 1 end
                if k == keys.enter then openApp(state.apps[state.sel]) end
                if k == keys.tab then
                    if next(state.openWindows) then
                        state.focusOnLauncher = false
                        wm.cycleFocus(1)
                    end
                end
            elseif kind == "char" then
                local c = ev[2]
                local n = tonumber(c)
                if n and state.apps[n] then openApp(state.apps[n])
                elseif c == "q" then quitDesktop()
                elseif c == "x" then closeFocused()
                end
            end
        else
            -- Forward to focused window first; intercept Tab/x/q.
            if kind == "key" and ev[2] == keys.tab then
                wm.cycleFocus(1)
                if not wm.focused() then state.focusOnLauncher = true end
                return
            end
            if kind == "char" then
                if ev[2] == "x" then closeFocused(); return end
            end
            local f = wm.focused()
            if f and f.onEvent then pcall(f.onEvent, f, ev) end
        end
    end

    term.setBackgroundColor(colors.black); term.clear()

    local function fullRender()
        term.setBackgroundColor(colors.black); term.clear()
        -- Apps go in the workspace; WM draws each window's box and body.
        wm.render()
        -- Chrome on top.
        drawTopBar(state)
        drawLauncher(state, state.sel)
        drawBottomBar(state)
    end
    fullRender()

    local TICK_HZ = 2
    local tickTimer = os.startTimer(1 / TICK_HZ)
    local INPUT_EVENTS = {
        char = true, key = true, key_up = true, paste = true,
        mouse_click = true, mouse_drag = true, mouse_scroll = true, mouse_up = true,
        term_resize = true, monitor_resize = true,
    }
    while state.running do
        local ev = { os.pullEventRaw() }
        if ev[1] == "terminate" then break end
        local needsRender = false
        if ev[1] == "timer" and ev[2] == tickTimer then
            for _, w in ipairs(wm.windows()) do
                if w.visible and w.onTick then pcall(w.onTick, w, 1 / TICK_HZ) end
            end
            tickTimer = os.startTimer(1 / TICK_HZ)
            needsRender = true
        elseif INPUT_EVENTS[ev[1]] then
            handleKey(ev)
            needsRender = true
        end
        if needsRender then fullRender() end
    end
    term.setTextColor(colors.white)
    term.setBackgroundColor(colors.black)
    term.clear()
    term.setCursorPos(1, 1)
    print("desktop: stopped.")
end

return M
