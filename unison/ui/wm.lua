-- Tiny TUI window manager.
--
-- Caller flow:
--   local wm = require_ui_wm()
--   wm.add(window)
--   wm.run()
--
-- Each window is a table:
--   {
--     id            = "...",      -- optional, generated if missing
--     x, y, w, h    = ...,         -- bounds (cells)
--     title         = "...",       -- shown on the box border
--     fg, bg        = colour,      -- defaults: white on black
--     focusable     = true,        -- can take keyboard/mouse focus
--     visible       = true,
--     render        = function(window, buf) end,
--     onEvent       = function(window, event_table) end,    -- returns "consumed"|nil|"quit"
--     onTick        = function(window, dt) end,
--   }
--
-- A timer event with id = wm._tickTimer drives a 4Hz refresh loop so windows
-- can update animations or polled data without managing timers themselves.

local Buffer = dofile("/unison/ui/buffer.lua")

local M = {}

local windows = {}
local focusIdx = nil
local running = false
local tickTimer = nil
local TICK_HZ = 2

-- Events that should trigger a redraw. Anything else (modem messages, ipc,
-- random timers from other coroutines) is ignored to keep the screen calm.
local INPUT_EVENTS = {
    char = true, key = true, key_up = true,
    mouse_click = true, mouse_drag = true, mouse_scroll = true, mouse_up = true,
    paste = true, term_resize = true, monitor_resize = true,
}

local function nextId()
    return "win-" .. tostring(os.epoch and os.epoch("utc") or os.time()) ..
           "-" .. tostring(math.random(0, 9999))
end

function M.add(win)
    win.id = win.id or nextId()
    if win.visible == nil then win.visible = true end
    if win.focusable == nil then win.focusable = true end
    windows[#windows + 1] = win
    if win.focusable and not focusIdx then focusIdx = #windows end
    return win
end

function M.remove(win)
    for i, w in ipairs(windows) do
        if w == win or w.id == win then
            table.remove(windows, i)
            if focusIdx and focusIdx >= i then focusIdx = math.max(1, focusIdx - 1) end
            if focusIdx and focusIdx > #windows then focusIdx = nil end
            return true
        end
    end
    return false
end

function M.windows() return windows end

function M.focus(win)
    for i, w in ipairs(windows) do
        if w == win or w.id == win then focusIdx = i; return true end
    end
    return false
end

function M.focused()
    if not focusIdx then return nil end
    return windows[focusIdx]
end

function M.cycleFocus(delta)
    delta = delta or 1
    local count = #windows
    if count == 0 then focusIdx = nil; return end
    local i = focusIdx or 0
    for _ = 1, count do
        i = ((i - 1 + delta) % count) + 1
        if windows[i].focusable and windows[i].visible then
            focusIdx = i
            return windows[i]
        end
    end
end

local function targetTerm()
    return term.current()
end

function M.render()
    local buf = Buffer.new(targetTerm())
    -- Each window's box paints its own background, so we skip term.clear()
    -- to eliminate flicker. Initial clear happens once in M.run().
    for i, w in ipairs(windows) do
        if w.visible then
            local fg = w.fg or colors.white
            local bg = w.bg or colors.black
            local titled = w.title
            if i == focusIdx and titled then titled = "* " .. w.title end
            buf:box(w.x, w.y, w.w, w.h, titled, fg, bg)
            if w.render then
                local sub = Buffer.new(targetTerm())
                local ok, err = pcall(w.render, w, sub)
                if not ok then
                    buf:text(w.x + 1, w.y + 1,
                        ("render err: " .. tostring(err)):sub(1, w.w - 2),
                        colors.red, bg)
                end
            end
        end
    end
end

local function dispatch(ev)
    -- Tab cycles focus
    if ev[1] == "key" and ev[2] == keys.tab then
        M.cycleFocus(1)
        return
    end
    if ev[1] == "key" and ev[2] == keys.q then
        running = false
        return
    end

    local target = M.focused()
    if not target or not target.onEvent then return end
    local res = target.onEvent(target, ev)
    if res == "quit" then running = false end
end

local function tickAll(dt)
    for _, w in ipairs(windows) do
        if w.visible and w.onTick then
            local ok, err = pcall(w.onTick, w, dt)
            if not ok then
                local log = unison and unison.kernel and unison.kernel.log
                if log then log.warn("ui-wm", "onTick: " .. tostring(err)) end
            end
        end
    end
end

function M.run()
    running = true
    -- Clean canvas exactly once.
    term.setBackgroundColor(colors.black)
    term.clear()
    M.render()
    tickTimer = os.startTimer(1 / TICK_HZ)
    while running do
        local ev = { os.pullEventRaw() }
        if ev[1] == "terminate" then
            running = false
            break
        end
        local needsRender = false
        if ev[1] == "timer" and ev[2] == tickTimer then
            tickAll(1 / TICK_HZ)
            tickTimer = os.startTimer(1 / TICK_HZ)
            needsRender = true
        elseif INPUT_EVENTS[ev[1]] then
            dispatch(ev)
            needsRender = true
        end
        if needsRender then M.render() end
    end
    -- restore terminal
    term.setTextColor(colors.white)
    term.setBackgroundColor(colors.black)
    term.clear()
    term.setCursorPos(1, 1)
end

function M.stop() running = false end

return M
