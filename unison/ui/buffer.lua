-- TUI drawing primitives.
--
-- A Buffer wraps any term-like object (term, monitor, multiplex from the
-- display service) and offers high-level helpers: filled rectangles,
-- bordered boxes with titles, hr/vr lines, positioned text. All routines
-- restore the previous text/background colour and cursor, so callers can
-- compose without bookkeeping.

local M = {}

local function isColor(t)
    if t.isColor then return t.isColor() end
    if t.isColour then return t.isColour() end
    return false
end

local Buffer = {}
Buffer.__index = Buffer

function M.new(target)
    target = target or term.current()
    return setmetatable({
        t = target,
        color = isColor(target),
    }, Buffer)
end

local function withColors(self, fg, bg, fn)
    local oldFg = self.t.getTextColor and self.t.getTextColor() or colors.white
    local oldBg = self.t.getBackgroundColor and self.t.getBackgroundColor() or colors.black
    if fg and self.t.setTextColor then self.t.setTextColor(fg) end
    if bg and self.t.setBackgroundColor then self.t.setBackgroundColor(bg) end
    fn()
    if self.t.setTextColor then self.t.setTextColor(oldFg) end
    if self.t.setBackgroundColor then self.t.setBackgroundColor(oldBg) end
end

function Buffer:size()
    return self.t.getSize()
end

function Buffer:clear(bg)
    withColors(self, nil, bg, function()
        self.t.clear()
        self.t.setCursorPos(1, 1)
    end)
end

function Buffer:text(x, y, str, fg, bg)
    if not str or str == "" then return end
    withColors(self, fg, bg, function()
        self.t.setCursorPos(x, y)
        self.t.write(str)
    end)
end

function Buffer:rect(x, y, w, h, ch, fg, bg)
    ch = ch or " "
    local line = string.rep(ch, w)
    withColors(self, fg, bg, function()
        for i = 0, h - 1 do
            self.t.setCursorPos(x, y + i)
            self.t.write(line)
        end
    end)
end

function Buffer:hline(x, y, w, ch, fg, bg)
    ch = ch or "-"
    self:text(x, y, string.rep(ch, w), fg, bg)
end

function Buffer:vline(x, y, h, ch, fg, bg)
    ch = ch or "|"
    withColors(self, fg, bg, function()
        for i = 0, h - 1 do
            self.t.setCursorPos(x, y + i)
            self.t.write(ch)
        end
    end)
end

function Buffer:box(x, y, w, h, title, fg, bg)
    self:rect(x, y, w, h, " ", fg, bg)
    -- corners + edges using simple ASCII so any monitor renders cleanly
    withColors(self, fg, bg, function()
        self.t.setCursorPos(x, y)
        self.t.write("+" .. string.rep("-", math.max(0, w - 2)) .. "+")
        self.t.setCursorPos(x, y + h - 1)
        self.t.write("+" .. string.rep("-", math.max(0, w - 2)) .. "+")
        for i = 1, h - 2 do
            self.t.setCursorPos(x, y + i)
            self.t.write("|")
            self.t.setCursorPos(x + w - 1, y + i)
            self.t.write("|")
        end
        if title and #title > 0 then
            local t = " " .. title .. " "
            if #t > w - 2 then t = t:sub(1, w - 2) end
            self.t.setCursorPos(x + math.floor((w - #t) / 2), y)
            self.t.write(t)
        end
    end)
end

-- Print text inside a box, wrapping at width and clipping at height.
function Buffer:wrappedText(x, y, w, h, str, fg, bg)
    if not str then return end
    local row = 0
    for line in tostring(str):gmatch("[^\r\n]*") do
        while #line > 0 and row < h do
            local piece = line:sub(1, w)
            self:text(x, y + row, piece, fg, bg)
            line = line:sub(w + 1)
            row = row + 1
        end
        if row >= h then return end
        row = row + 0   -- gmatch yields a final empty line; ignore
    end
end

return M
