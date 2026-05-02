-- TUI drawing primitives.
--
-- A Buffer wraps any term-like target (term.current(), a monitor, the
-- display multiplex, a gdi.Bitmap target). Public surface is unchanged
-- from earlier versions — :clear, :text, :rect, :hline, :vline, :box,
-- :wrappedText — but every method now goes through unison.lib.gdi so
-- there's exactly one drawing pipeline in the OS.
--
-- All routines preserve the previous text/background colour and cursor
-- (gdi.Context:with handles save/restore), so callers can compose
-- without bookkeeping.

local gdi = dofile("/unison/lib/gdi/init.lua")

local M = {}

local Buffer = {}
Buffer.__index = Buffer

function M.new(target)
    target = target or term.current()
    return setmetatable({
        t   = target,
        ctx = gdi.fromTarget(target),
    }, Buffer)
end

function Buffer:target() return self.t end
function Buffer:context() return self.ctx end

function Buffer:size() return self.ctx:size() end

function Buffer:clear(bg)
    -- Filling the whole rectangle keeps the right semantics: previous
    -- on-screen content is wiped and replaced with `bg`. Falls back to
    -- the target's own clear when bg is nil so existing call sites
    -- (Buffer:clear() with no arg) keep their existing behaviour.
    if bg then
        local w, h = self:size()
        self.ctx:fillRect(1, 1, w, h, bg)
        self.ctx:setCursor(1, 1)
    else
        local t = self.t
        if t.clear then t.clear() end
        if t.setCursorPos then t.setCursorPos(1, 1) end
    end
end

function Buffer:text(x, y, str, fg, bg)
    if not str or str == "" then return end
    self.ctx:drawText(x, y, str, fg, bg)
end

function Buffer:rect(x, y, w, h, ch, fg, bg)
    if w < 1 or h < 1 then return end
    if (not ch) or ch == " " then
        self.ctx:fillRect(x, y, w, h, bg or fg)
        return
    end
    -- Custom fill char: paint the rectangle one row at a time. Keeps
    -- pen/brush state via :with so callers don't have to.
    local row = string.rep(ch, w)
    self.ctx:with(function(c)
        if fg then c:setPen(fg) end
        if bg then c:setBrush(bg) end
        for i = 0, h - 1 do
            c:setCursor(x, y + i)
            c:_rawWrite(row)
        end
    end)
end

function Buffer:hline(x, y, w, ch, fg, bg)
    self.ctx:with(function(c)
        if fg then c:setPen(fg) end
        if bg then c:setBrush(bg) end
        c:hLine(x, y, w, ch or "-")
    end)
end

function Buffer:vline(x, y, h, ch, fg, bg)
    self.ctx:with(function(c)
        if fg then c:setPen(fg) end
        if bg then c:setBrush(bg) end
        c:vLine(x, y, h, ch or "|")
    end)
end

-- Filled box with ASCII border + optional centred title. Border uses
-- "+|-" so any monitor renders cleanly regardless of font feature.
function Buffer:box(x, y, w, h, title, fg, bg)
    if w < 2 or h < 2 then return end
    self:rect(x, y, w, h, " ", fg, bg)
    self.ctx:with(function(c)
        if fg then c:setPen(fg) end
        if bg then c:setBrush(bg) end
        c:rect(x, y, w, h)
        if title and #title > 0 then
            local t = " " .. title .. " "
            if #t > w - 2 then t = t:sub(1, w - 2) end
            c:setCursor(x + math.floor((w - #t) / 2), y)
            c:_rawWrite(t)
        end
    end)
end

-- Print text inside a w x h box, wrapping at width and clipping at
-- height. Honors embedded \n / \r.
function Buffer:wrappedText(x, y, w, h, str, fg, bg)
    if not str or w < 1 or h < 1 then return end
    self.ctx:drawTextRect(x, y, w, h, str, fg, bg)
end

return M
