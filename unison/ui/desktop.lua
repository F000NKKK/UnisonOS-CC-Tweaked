-- unison.ui.desktop — TUI shell with pixel-based decorations.
--
-- Layout:
--   top bar    (1 cell row, painted as pixels via canvas)
--   workspace  (the rest, app windows on the left)
--   launcher   (right side column)
--   bottom bar (1 cell row, hint pixmap)
--
-- Keybindings (no Ctrl combos — CC doesn't expose modifier state):
--   Tab           cycle window focus
--   q             quit desktop (from launcher)
--   x             close focused app    (from launcher)
--   1..9          fast-launch app N
--   Up/Down/Enter navigate launcher
--
-- Apps live in /unison/ui/apps/<name>.lua and return
--   { id, title, roles, make(geom) -> window-table }

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
            local mod, err = loadApp(f)
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
-- Pixel chrome (top bar / bottom bar / icons)
----------------------------------------------------------------------

-- Picks an "icon colour" deterministically per-app id, cycling through
-- a curated palette of CC colours. Same app always gets the same hue.
local ICON_PALETTE = {
    colors.lightBlue, colors.lime, colors.orange, colors.magenta,
    colors.yellow, colors.cyan, colors.pink, colors.purple,
    colors.red, colors.green,
}
local function iconColor(id)
    local h = 0
    for i = 1, #id do h = (h * 31 + id:byte(i)) % 1000003 end
    return ICON_PALETTE[(h % #ICON_PALETTE) + 1]
end

local function drawTopBar(state)
    local t = term.current()
    -- Full-width gradient: dark grey base + accent pixel run.
    t.setCursorPos(1, 1)
    t.setBackgroundColor(colors.gray)
    t.setTextColor(colors.white)
    t.write(string.rep(" ", state.W))
    -- Accent pixel block on the left.
    t.setCursorPos(1, 1)
    t.setBackgroundColor(colors.cyan); t.write("  ")
    t.setBackgroundColor(colors.lightBlue); t.write("  ")
    t.setBackgroundColor(colors.gray); t.setTextColor(colors.white)
    -- Title.
    local node = (unison and unison.node) or "?"
    local role = (unison and unison.role) or "?"
    t.setCursorPos(6, 1)
    t.write(string.format("UnisonOS  %s  %s", node, role))
    -- Focused app on the right.
    local f = wm.focused()
    local title = (f and f.title) or ""
    local right = title and (" [ " .. title .. " ] ") or ""
    local time = textutils.formatTime(os.time(), false)
    local rstr = right .. " " .. time .. " "
    t.setCursorPos(state.W - #rstr + 1, 1); t.write(rstr)
end

local function drawBottomBar(state)
    local t = term.current()
    t.setCursorPos(1, state.H)
    t.setBackgroundColor(colors.lightGray)
    t.setTextColor(colors.black)
    local hint = " Tab cycle  |  Up/Down navigate  |  Enter open  |  x close  |  q quit "
    if #hint > state.W then hint = hint:sub(1, state.W) end
    hint = hint .. string.rep(" ", state.W - #hint)
    t.write(hint)
end

----------------------------------------------------------------------
-- Launcher window — uses pixel "icons" (colored squares) per app.
----------------------------------------------------------------------

local function makeLauncher(state, openApp, quitDesktop, closeFocused)
    local lw = 22
    local lx = state.W - lw + 1
    local sel = 1

    return {
        id = "desk:launcher",
        x = lx, y = 2, w = lw, h = state.H - 2,
        title = nil, focusable = true,
        render = function(self, _)
            local t = term.current()
            -- Background panel.
            for row = 0, self.h - 1 do
                t.setCursorPos(self.x, self.y + row)
                t.setBackgroundColor(colors.black)
                t.write(string.rep(" ", self.w))
            end
            -- Header strip.
            t.setCursorPos(self.x, self.y)
            t.setBackgroundColor(colors.gray); t.setTextColor(colors.white)
            t.write(" Apps" .. string.rep(" ", self.w - 5))

            -- Each app row: 2-cell colored "icon" + space + title.
            local rowY = self.y + 2
            for i, app in ipairs(state.apps) do
                if rowY >= self.y + self.h - 2 then break end
                local label = string.format("%d %s", i, app.title or app.id)
                if #label > self.w - 5 then label = label:sub(1, self.w - 5) end
                -- icon
                t.setCursorPos(self.x + 1, rowY)
                t.setBackgroundColor(iconColor(app.id or app.title))
                t.write("  ")
                -- gap + label
                t.setBackgroundColor((i == sel) and colors.yellow or colors.black)
                t.setTextColor((i == sel) and colors.black or colors.white)
                local rest = " " .. label .. string.rep(" ", self.w - 5 - #label)
                t.write(rest)
                rowY = rowY + 1
            end

            -- Footer: ascii actions.
            t.setCursorPos(self.x, self.y + self.h - 1)
            t.setBackgroundColor(colors.gray); t.setTextColor(colors.lightGray)
            local foot = " 1-9 quick  Enter open"
            if #foot > self.w then foot = foot:sub(1, self.w) end
            t.write(foot .. string.rep(" ", self.w - #foot))
        end,
        onEvent = function(self, ev)
            if ev[1] == "key" then
                local k = ev[2]
                if k == keys.up   and sel > 1               then sel = sel - 1; return "consumed" end
                if k == keys.down and sel < #state.apps     then sel = sel + 1; return "consumed" end
                if k == keys.enter then openApp(state.apps[sel]); return "consumed" end
                if k == keys.q then quitDesktop(); return "consumed" end
                if k == keys.x then closeFocused(); return "consumed" end
            elseif ev[1] == "char" then
                local n = tonumber(ev[2])
                if n and state.apps[n] then openApp(state.apps[n]); return "consumed" end
                if ev[2] == "q" then quitDesktop(); return "consumed" end
                if ev[2] == "x" then closeFocused(); return "consumed" end
            end
        end,
    }
end

----------------------------------------------------------------------
-- Run loop. We don't reuse wm.run() because we need our own redraw
-- sequence (top/bottom chrome painted directly each frame, then WM
-- paints windows on top).
----------------------------------------------------------------------

function M.run(opts)
    opts = opts or {}
    local W, H = term.getSize()
    local role = (unison and unison.role) or "any"

    local apps = {}
    for _, a in ipairs(discoverApps()) do
        if appAllowedHere(a, role) then apps[#apps + 1] = a end
    end

    local state = { W = W, H = H, apps = apps, openWindows = {}, running = true }

    local function openApp(app)
        if not (app and app.make) then return end
        local existing = state.openWindows[app.id]
        if existing and existing.visible then wm.focus(existing); return end
        local lw = 22
        local win = app.make({
            x = 1, y = 2, w = W - lw, h = H - 2,
        })
        win.title = win.title or app.title or app.id
        state.openWindows[app.id] = win
        wm.add(win); wm.focus(win)
    end

    local function closeFocused()
        local f = wm.focused()
        if not f or not f.id or f.id == "desk:launcher" then return end
        for id, w in pairs(state.openWindows) do
            if w == f then state.openWindows[id] = nil; break end
        end
        wm.remove(f)
    end

    local function quitDesktop() state.running = false end

    local launcher = makeLauncher(state, openApp, quitDesktop, closeFocused)
    wm.add(launcher)
    wm.focus(launcher)

    term.setBackgroundColor(colors.black)
    term.clear()

    local function fullRender()
        term.setBackgroundColor(colors.black); term.clear()
        wm.render()
        drawTopBar(state)
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
            if ev[1] == "key" and ev[2] == keys.tab then
                wm.cycleFocus(1)
            else
                local f = wm.focused()
                if f and f.onEvent then
                    pcall(f.onEvent, f, ev)
                end
            end
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
