-- unison.ui.desktop — a tiny graphical shell built on the WM.
--
-- Layout (top to bottom):
--   top panel (1 row)   : clock, hostname, role, focused app, Ctrl+Q hint
--   workspace (rest)    : active app windows on the left, app launcher on right
--
-- Hotkeys (handled before windows see events):
--   Tab            cycle window focus   (WM default)
--   Ctrl+Q         quit desktop, return to shell
--   Ctrl+W         close the focused app
--   1..9           open the N-th app from the launcher
--
-- Each "app" is a constructor returning a window table the WM can render.
-- Apps live in /unison/ui/apps/<name>.lua and return a function(opts) that
-- returns a fresh window. Adding a new app is one file, no kernel changes.

local wm     = dofile("/unison/ui/wm.lua")
local Buffer = dofile("/unison/ui/buffer.lua")

local M = {}

local APPS_DIR = "/unison/ui/apps"

-- ---- App discovery -------------------------------------------------------

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
            if mod then out[#out + 1] = mod
            else
                local log = unison and unison.kernel and unison.kernel.log
                if log then log.warn("desktop", "skip " .. f .. ": " .. tostring(err)) end
            end
        end
    end
    table.sort(out, function(a, b) return (a.title or "") < (b.title or "") end)
    return out
end

-- Filter by device role: app.roles = { "any" } or { "turtle", "computer" }.
local function appAllowedHere(app, role)
    if not app.roles or #app.roles == 0 then return true end
    for _, r in ipairs(app.roles) do
        if r == "any" or r == role then return true end
    end
    return false
end

-- ---- Top panel -----------------------------------------------------------

local function makeTopPanel(state)
    return {
        id = "desk:top", focusable = false,
        x = 1, y = 1, w = state.W, h = 1,
        render = function(self, _)
            local term_ = term.current()
            term_.setCursorPos(1, 1)
            term_.setBackgroundColor(colors.gray)
            term_.setTextColor(colors.white)
            term_.write(string.rep(" ", state.W))
            local time = textutils.formatTime(os.time(), false)
            local node = (unison and unison.node) or "?"
            local role = (unison and unison.role) or "?"
            local left = string.format(" UnisonOS  %s  %s ", node, role)
            local focused = wm.focused()
            local centre = focused and (" [ " .. (focused.title or "?") .. " ] ") or ""
            local right = string.format(" %s  Ctrl+Q quit ", time)
            term_.setCursorPos(1, 1); term_.write(left)
            if #centre > 0 then
                local cx = math.floor((state.W - #centre) / 2)
                term_.setCursorPos(math.max(#left + 1, cx), 1); term_.write(centre)
            end
            term_.setCursorPos(state.W - #right + 1, 1); term_.write(right)
        end,
        onTick = function(self) end,   -- panel re-renders every tick automatically
    }
end

-- ---- Launcher ------------------------------------------------------------

local function makeLauncher(state, openApp)
    local lw = 18
    local lx = state.W - lw + 1
    local items = {}
    for i, app in ipairs(state.apps) do
        items[i] = (i <= 9 and tostring(i) .. " " or "  ") .. (app.title or app.id)
    end
    local sel = 1
    return {
        id = "desk:launcher",
        x = lx, y = 2, w = lw, h = state.H - 1,
        title = "Apps", focusable = true,
        render = function(self, _)
            local b = Buffer.new(term.current())
            for i = 1, #items do
                local row = items[i]
                if #row > self.w - 2 then row = row:sub(1, self.w - 2) end
                row = row .. string.rep(" ", self.w - 2 - #row)
                local fg, bg = colors.white, colors.black
                if i == sel then fg, bg = colors.black, colors.yellow end
                b:text(self.x + 1, self.y + i, row, fg, bg)
            end
            b:text(self.x + 1, self.y + self.h - 2,
                "Enter:open  1-9:fast", colors.lightGray, colors.black)
        end,
        onEvent = function(self, ev)
            if ev[1] == "key" then
                local k = ev[2]
                if k == keys.up   and sel > 1       then sel = sel - 1; return "consumed" end
                if k == keys.down and sel < #items  then sel = sel + 1; return "consumed" end
                if k == keys.enter then openApp(state.apps[sel]); return "consumed" end
            elseif ev[1] == "char" then
                local n = tonumber(ev[2])
                if n and state.apps[n] then openApp(state.apps[n]); return "consumed" end
            end
        end,
    }
end

-- ---- Run -----------------------------------------------------------------

function M.run(opts)
    opts = opts or {}
    local W, H = term.getSize()
    local role = (unison and unison.role) or "any"

    local apps = {}
    for _, a in ipairs(discoverApps()) do
        if appAllowedHere(a, role) then apps[#apps + 1] = a end
    end

    local state = { W = W, H = H, apps = apps, openWindows = {} }

    local function openApp(app)
        if not (app and app.make) then return end
        local existing = state.openWindows[app.id]
        if existing and existing.visible then
            wm.focus(existing); return
        end
        local lw = 18
        local win = app.make({
            x = 2, y = 3, w = W - lw - 2, h = H - 3,
        })
        win.title = win.title or app.title or app.id
        state.openWindows[app.id] = win
        wm.add(win); wm.focus(win)
    end

    local function closeFocused()
        local f = wm.focused()
        if not f or not f.id or f.id == "desk:top" or f.id == "desk:launcher" then return end
        for id, w in pairs(state.openWindows) do
            if w == f then state.openWindows[id] = nil; break end
        end
        wm.remove(f)
    end

    -- Hotkey overlay: invisible window that gets keys before the launcher.
    -- We piggy-back on a focusable window whose render does nothing; but
    -- WM dispatches based on focus, so instead we wrap the WM's run:
    -- hook into INPUT_EVENTS via a pre-dispatch by adding a "shell" window.
    --
    -- Simpler: pre-register a high-priority hotkey window that's the very
    -- first child and never loses keys. We approximate by making it
    -- non-focusable but with onEvent — but WM only sends events to focused
    -- window. So instead we override behaviour with a wrapper:
    local desktopRunning = true
    local hotkey = {
        id = "desk:hotkey", x = 1, y = H, w = W, h = 1,
        focusable = false,
        render = function(self, _)
            local b = Buffer.new(term.current())
            b:text(1, H, " Tab cycle | Ctrl+W close app | Ctrl+Q quit ",
                colors.lightGray, colors.gray)
            local pad = W - 44
            if pad > 0 then
                b:text(45, H, string.rep(" ", pad), colors.lightGray, colors.gray)
            end
        end,
    }

    wm.add(makeTopPanel(state))
    wm.add(hotkey)
    local launcher = makeLauncher(state, openApp)
    wm.add(launcher)
    wm.focus(launcher)

    -- We re-implement the run loop here so we can intercept Ctrl+Q / Ctrl+W
    -- before the WM sees them. Mirrors the body of wm.run().
    term.setBackgroundColor(colors.black)
    term.clear()
    wm.render()
    local TICK_HZ = 2
    local tickTimer = os.startTimer(1 / TICK_HZ)
    local INPUT_EVENTS = {
        char = true, key = true, key_up = true, paste = true,
        mouse_click = true, mouse_drag = true, mouse_scroll = true, mouse_up = true,
        term_resize = true, monitor_resize = true,
    }
    while desktopRunning do
        local ev = { os.pullEventRaw() }
        if ev[1] == "terminate" then break end

        -- Hotkeys.
        if ev[1] == "key" then
            local k = ev[2]
            local ctrl = ev[3]   -- "held" flag is ev[3]; CC reports modifier via lctrl
            -- ev[3] is "held" not "ctrl". Detect ctrl by tracking key state.
            -- Simpler: check for keys.leftCtrl / keys.rightCtrl held via os.queueEvent? Not directly.
            -- Workaround: use leader key Esc + letter. But user requested Ctrl+Q.
            -- CC does not surface modifier state in key events; we approximate
            -- by checking whether leftCtrl is currently held via an internal table.
            -- (See ctrlHeld below.)
        end

        local needsRender = false
        if ev[1] == "timer" and ev[2] == tickTimer then
            for _, w in ipairs(wm.windows()) do
                if w.visible and w.onTick then pcall(w.onTick, w, 1 / TICK_HZ) end
            end
            tickTimer = os.startTimer(1 / TICK_HZ)
            needsRender = true
        elseif INPUT_EVENTS[ev[1]] then
            -- Manual ctrl detection: track lCtrl down/up.
            if ev[1] == "key" then
                if ev[2] == keys.leftCtrl or ev[2] == keys.rightCtrl then
                    state.ctrlDown = true
                elseif state.ctrlDown then
                    if ev[2] == keys.q then desktopRunning = false; break end
                    if ev[2] == keys.w then closeFocused(); needsRender = true end
                end
            elseif ev[1] == "key_up" then
                if ev[2] == keys.leftCtrl or ev[2] == keys.rightCtrl then
                    state.ctrlDown = false
                end
            end
            -- Otherwise pass to focused window via WM.
            if not state.ctrlDown then
                if ev[1] == "key" and ev[2] == keys.tab then
                    wm.cycleFocus(1)
                else
                    local f = wm.focused()
                    if f and f.onEvent then
                        local ok, res = pcall(f.onEvent, f, ev)
                        if ok and res == "quit" then desktopRunning = false; break end
                    end
                end
            end
            needsRender = true
        end
        if needsRender then wm.render() end
    end
    term.setTextColor(colors.white)
    term.setBackgroundColor(colors.black)
    term.clear()
    term.setCursorPos(1, 1)
    print("desktop: stopped.")
end

return M
