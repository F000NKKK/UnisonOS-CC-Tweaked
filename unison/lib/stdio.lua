-- unison.lib.stdio — text I/O over the active term-target.
--
-- The single source of truth for textual output. Apps, kernel and shell
-- write through `unison.stdio` instead of `term.*` directly, so there
-- is exactly one path that lands characters on the screen.
--
-- Lazy target. A stream's `.t` is nil for "live" streams — every
-- operation resolves through `term.current()` at call time, which
-- means once display.start() does `term.redirect(multiplex)` the
-- stream's writes mirror into the Shadow → physical monitors. If the
-- target were captured at construction (which is when this module
-- loads — BEFORE display.start runs) the stream would write straight
-- to the raw primary terminal and monitors would never see it. The
-- explicit `:redirect(target)` call freezes a stream onto a specific
-- target (e.g. a gdi.Bitmap); :redirect(nil) puts it back into live
-- mode.
--
-- Streams:
--   stdio.stdout   — write/writeln/print
--   stdio.stderr   — printError (red)
--   stdio.stdin    — read(prompt) reads from CC keyboard
--
-- Display knobs (peripheral-side: enabled, scale, background) live
-- under stdio.displays.* and just delegate to the display service.

local M = {}

local DEFAULT_FG = colors.white
local DEFAULT_BG = colors.black

local Stream = {}
Stream.__index = Stream

local function newStream(kind)
    return setmetatable({
        t    = nil,             -- nil = live (resolves through term.current())
        kind = kind or "out",
    }, Stream)
end

-- Resolve the active target at call time. nil .t = live terminal,
-- otherwise the explicit target the stream was redirected to.
local function active(self)
    return self.t or term.current()
end

function Stream:target() return active(self) end
function Stream:isLive() return self.t == nil end

-- Redirect this stream to an explicit term-like target. Pass nil to
-- go back to live mode (writes follow term.current()).
function Stream:redirect(target) self.t = target end

function Stream:size()
    local t = active(self)
    if not t.getSize then return 51, 19 end
    return t.getSize()
end

function Stream:cursor()
    local t = active(self)
    if not t.getCursorPos then return 1, 1 end
    return t.getCursorPos()
end

function Stream:setCursor(x, y)
    local t = active(self)
    if t.setCursorPos then t.setCursorPos(x, y) end
end

function Stream:setColor(fg, bg)
    local t = active(self)
    if fg and t.setTextColor then t.setTextColor(fg) end
    if bg and t.setBackgroundColor then t.setBackgroundColor(bg) end
end

function Stream:getColor()
    local t = active(self)
    local fg = t.getTextColor and t.getTextColor() or DEFAULT_FG
    local bg = t.getBackgroundColor and t.getBackgroundColor() or DEFAULT_BG
    return fg, bg
end

function Stream:isColor()
    local t = active(self)
    if t.isColor then return t.isColor() end
    if t.isColour then return t.isColour() end
    return false
end

function Stream:setCursorBlink(b)
    local t = active(self)
    if t.setCursorBlink then t.setCursorBlink(b and true or false) end
end

local function joinArgs(...)
    local n = select("#", ...)
    if n == 0 then return "" end
    local parts = {}
    for i = 1, n do parts[i] = tostring((select(i, ...))) end
    return table.concat(parts, "\t")
end

function Stream:write(s)
    local t = active(self)
    if t.write then t.write(tostring(s or "")) end
end

-- Append \n. CC handles wrap/scroll itself when writing to the live
-- terminal; for redirected (off-screen) targets we don't try to be
-- clever — clients of off-screen targets manage their own scroll.
function Stream:writeln(s)
    self:write(s)
    local t = active(self)
    if t.write then t.write("\n") end
end

-- Use CC's `print` on live streams so word-wrap + scroll behave
-- exactly like a vanilla CC program. On redirected streams fall back
-- to writeln(joined args).
function Stream:print(...)
    if self:isLive() and print then
        return print(...)
    end
    self:writeln(joinArgs(...))
end

function Stream:printError(...)
    if self:isLive() and printError then
        return printError(...)
    end
    local t = active(self)
    local prevFg = t.getTextColor and t.getTextColor() or DEFAULT_FG
    if t.setTextColor then t.setTextColor(colors.red) end
    self:writeln(joinArgs(...))
    if t.setTextColor then t.setTextColor(prevFg) end
end

function Stream:clear()
    local t = active(self)
    if t.clear then t.clear() end
    if t.setCursorPos then t.setCursorPos(1, 1) end
end

function Stream:clearLine()
    local t = active(self)
    if t.clearLine then t.clearLine() end
end

function Stream:scroll(n)
    local t = active(self)
    if t.scroll then t.scroll(n or 1) end
end

-- read(prompt, history, complete, default). Always reads from the
-- live keyboard via CC's `read`; redirecting stdin onto a non-live
-- target is not supported (CC limitation).
function Stream:read(prompt, history, complete, default)
    if prompt then self:write(prompt) end
    if not read then return nil end
    return read(nil, history, complete, default)
end

----------------------------------------------------------------------
-- Default streams + module-level convenience.
----------------------------------------------------------------------

M.stdout = newStream("out")
M.stderr = newStream("err")
M.stdin  = newStream("in")

function M.write(s)         return M.stdout:write(s) end
function M.writeln(s)       return M.stdout:writeln(s) end
function M.print(...)       return M.stdout:print(...) end
function M.printError(...)  return M.stderr:printError(...) end
function M.read(p, h, c, d) return M.stdin:read(p, h, c, d) end
function M.clear()          return M.stdout:clear() end
function M.clearLine()      return M.stdout:clearLine() end
function M.scroll(n)        return M.stdout:scroll(n) end
function M.size()           return M.stdout:size() end
function M.cursor()         return M.stdout:cursor() end
function M.setCursor(x, y)  return M.stdout:setCursor(x, y) end
function M.setColor(fg, bg) return M.stdout:setColor(fg, bg) end
function M.getColor()       return M.stdout:getColor() end
function M.isColor()        return M.stdout:isColor() end
function M.setCursorBlink(b)return M.stdout:setCursorBlink(b) end
function M.target()         return M.stdout:target() end

-- Build a stream tied to an arbitrary term-target (e.g. a bitmap).
-- The result is in non-live mode from the start: write/print emit a
-- plain writeln, no CC bias.
function M.streamFromTarget(t, kind)
    local s = newStream(kind)
    s.t = t
    return s
end

----------------------------------------------------------------------
-- Display knobs delegated to the display service when available.
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
