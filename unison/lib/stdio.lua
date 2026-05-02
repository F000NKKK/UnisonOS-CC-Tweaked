-- unison.lib.stdio — text I/O over the active term-target.
--
-- The single source of truth for textual output. Apps, kernel and shell
-- write through `unison.stdio` instead of `term.*` directly, so there is
-- exactly one path that lands characters on the screen.
--
-- Under the hood every stream points at `term.current()`. After
-- `display.start()` runs, that's the display multiplex (which mirrors
-- writes into the Shadow grid → physical monitors). Before display has
-- started, it's the raw primary terminal — output still works, it just
-- doesn't reach monitors yet.
--
-- Streams:
--   stdio.stdout   — writes go through here (writeln, print, write)
--   stdio.stderr   — printError lands here in red
--   stdio.stdin    — read(prompt) reads from CC keyboard
--
-- All three can be redirected to any other term-like target (e.g. a
-- gdi.Bitmap) via stream:redirect(target). Module-level helpers
-- (stdio.write, stdio.print, ...) always go through the default streams.
--
-- Display knobs (peripheral-side: enabled, scale, background) live under
-- stdio.displays.* and just delegate to the display service.

local M = {}

local DEFAULT_FG = colors.white
local DEFAULT_BG = colors.black

local Stream = {}
Stream.__index = Stream

local function defaultTarget() return term.current() end

local function newStream(target, kind)
    return setmetatable({
        t    = target or defaultTarget(),
        kind = kind or "out",
    }, Stream)
end

function Stream:target() return self.t end

-- Redirect this stream onto another term-target (anything with the term
-- API: term itself, a window, a gdi.Bitmap target). nil resets to the
-- current active terminal.
function Stream:redirect(target) self.t = target or defaultTarget() end

function Stream:size()
    if not self.t.getSize then return 51, 19 end
    return self.t.getSize()
end

function Stream:cursor()
    if not self.t.getCursorPos then return 1, 1 end
    return self.t.getCursorPos()
end

function Stream:setCursor(x, y)
    if self.t.setCursorPos then self.t.setCursorPos(x, y) end
end

function Stream:setColor(fg, bg)
    if fg and self.t.setTextColor then self.t.setTextColor(fg) end
    if bg and self.t.setBackgroundColor then self.t.setBackgroundColor(bg) end
end

function Stream:getColor()
    local fg = self.t.getTextColor and self.t.getTextColor() or DEFAULT_FG
    local bg = self.t.getBackgroundColor and self.t.getBackgroundColor() or DEFAULT_BG
    return fg, bg
end

function Stream:isColor()
    if self.t.isColor then return self.t.isColor() end
    if self.t.isColour then return self.t.isColour() end
    return false
end

local function joinArgs(...)
    local n = select("#", ...)
    if n == 0 then return "" end
    local parts = {}
    for i = 1, n do parts[i] = tostring((select(i, ...))) end
    return table.concat(parts, "\t")
end

function Stream:write(s)
    if self.t.write then self.t.write(tostring(s or "")) end
end

function Stream:writeln(s)
    self:write(s)
    if self.t.write then self.t.write("\n") end
    -- CC `print` handles cursor wrap + scroll; emulate by re-using it
    -- when the target IS the active terminal.
    if self.t == term.current() then
        local _, y = self:cursor()
        local _, h = self:size()
        if y > h then self:scroll(1); self:setCursor(1, h) end
    end
end

function Stream:print(...)
    -- Defer to CC's print() when we're on the active terminal: it
    -- handles word-wrap + scroll properly. Otherwise fall back to a
    -- plain write+newline.
    if self.t == term.current() and print then
        return print(...)
    end
    self:writeln(joinArgs(...))
end

function Stream:printError(...)
    if self.t == term.current() and printError then
        return printError(...)
    end
    local prevFg = self:getColor()
    if self.t.setTextColor then self.t.setTextColor(colors.red) end
    self:writeln(joinArgs(...))
    if self.t.setTextColor then self.t.setTextColor(prevFg) end
end

function Stream:clear()
    if self.t.clear then self.t.clear() end
    if self.t.setCursorPos then self.t.setCursorPos(1, 1) end
end

function Stream:clearLine()
    if self.t.clearLine then self.t.clearLine() end
end

function Stream:scroll(n)
    if self.t.scroll then self.t.scroll(n or 1) end
end

function Stream:read(prompt, history, complete, default)
    if prompt then self:write(prompt) end
    if not read then return nil end
    return read(nil, history, complete, default)
end

----------------------------------------------------------------------
-- Default streams + module-level convenience.
----------------------------------------------------------------------

M.stdout = newStream(nil, "out")
M.stderr = newStream(nil, "err")
M.stdin  = newStream(nil, "in")

function M.write(s)        return M.stdout:write(s) end
function M.writeln(s)      return M.stdout:writeln(s) end
function M.print(...)      return M.stdout:print(...) end
function M.printError(...) return M.stderr:printError(...) end
function M.read(p, h, c, d)return M.stdin:read(p, h, c, d) end
function M.clear()         return M.stdout:clear() end
function M.clearLine()     return M.stdout:clearLine() end
function M.scroll(n)       return M.stdout:scroll(n) end
function M.size()          return M.stdout:size() end
function M.cursor()        return M.stdout:cursor() end
function M.setCursor(x, y) return M.stdout:setCursor(x, y) end
function M.setColor(fg, bg)return M.stdout:setColor(fg, bg) end
function M.getColor()      return M.stdout:getColor() end
function M.isColor()       return M.stdout:isColor() end

-- Build a stream over an arbitrary term-target. Useful when an app
-- wants to capture stdout into a bitmap or off-screen window.
function M.streamFromTarget(t, kind) return newStream(t, kind) end

----------------------------------------------------------------------
-- Display knobs (delegated to the display service when available).
-- This is the user-facing surface for what `displays` shell command
-- used to do. Logical I/O = stdio; physical-monitor settings hang off
-- it under .displays.* so apps don't have to reach into unison.display.
----------------------------------------------------------------------

local function disp() return unison and unison.display end

M.displays = {
    list = function()
        local d = disp(); return d and d.list() or {}
    end,
    setEnabled = function(name, enabled)
        local d = disp(); if d then d.setEnabled(name, enabled) end
    end,
    setScale = function(name, scale)
        local d = disp(); if d then d.setScale(name, scale) end
    end,
    setBackground = function(name, color)
        local d = disp(); if d then d.setBackground(name, color) end
    end,
    refresh = function()
        local d = disp(); if d then d.refresh() end
    end,
}

return M
