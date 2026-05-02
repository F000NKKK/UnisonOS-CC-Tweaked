-- unison.lib.canvas — pixel-style drawing helpers.
--
-- Two modes:
--   M.cell(target)     -> a thin wrapper over paintutils (one pixel per
--                          terminal cell; correct for paintutils-style art)
--   M.subpixel(target) -> a virtual W x 2H buffer. Each cell shows two
--                          stacked sub-pixels using the half-block
--                          character; flush() blits the buffer to the
--                          target. Doubles vertical resolution.
--
-- Both expose: clear, pixel, line, rect (outline), filledRect, text.
-- Subpixel additionally has flush(), and its coords are 1..W, 1..(2H).
--
-- Colours are CC `colors.*` constants.

local M = {}

----------------------------------------------------------------------
-- Cell-level (paintutils)
----------------------------------------------------------------------

local Cell = {}; Cell.__index = Cell

function M.cell(target)
    target = target or term.current()
    local w, h = target.getSize()
    return setmetatable({ t = target, w = w, h = h }, Cell)
end

function Cell:size() return self.w, self.h end

function Cell:clear(c)
    c = c or colors.black
    local prevBg = self.t.getBackgroundColor and self.t.getBackgroundColor() or colors.black
    self.t.setBackgroundColor(c)
    self.t.clear()
    self.t.setCursorPos(1, 1)
    self.t.setBackgroundColor(prevBg)
end

local function withTarget(self, fn)
    local prev = term.current and term.current()
    if term.redirect then term.redirect(self.t) end
    local ok, err = pcall(fn)
    if term.redirect and prev then term.redirect(prev) end
    if not ok then error(err, 2) end
end

function Cell:pixel(x, y, c)
    withTarget(self, function() paintutils.drawPixel(x, y, c) end)
end
function Cell:line(x1, y1, x2, y2, c)
    withTarget(self, function() paintutils.drawLine(x1, y1, x2, y2, c) end)
end
function Cell:rect(x1, y1, x2, y2, c)
    withTarget(self, function() paintutils.drawBox(x1, y1, x2, y2, c) end)
end
function Cell:filledRect(x1, y1, x2, y2, c)
    withTarget(self, function() paintutils.drawFilledBox(x1, y1, x2, y2, c) end)
end
function Cell:text(x, y, str, fg, bg)
    local pf = self.t.getTextColor and self.t.getTextColor() or colors.white
    local pb = self.t.getBackgroundColor and self.t.getBackgroundColor() or colors.black
    if fg then self.t.setTextColor(fg) end
    if bg then self.t.setBackgroundColor(bg) end
    self.t.setCursorPos(x, y)
    self.t.write(str or "")
    self.t.setTextColor(pf); self.t.setBackgroundColor(pb)
end

----------------------------------------------------------------------
-- Sub-pixel buffer (2x vertical resolution via the half-block char)
----------------------------------------------------------------------

local Sub = {}; Sub.__index = Sub

local fmt = dofile("/unison/lib/fmt.lua")
local HALF_BLOCK = fmt.HALF_BLOCK
local function colorHex(c) return fmt.colorHex(c) end

function M.subpixel(target)
    target = target or term.current()
    local cw, ch = target.getSize()
    local self = setmetatable({
        t = target,
        cw = cw, ch = ch,
        w = cw, h = ch * 2,
        bg = colors.black,
        rows = {},
    }, Sub)
    self:clear()
    return self
end

function Sub:size() return self.w, self.h end

function Sub:clear(c)
    c = c or self.bg
    self.bg = c
    self.rows = {}
end

function Sub:pixel(x, y, c)
    if x < 1 or x > self.w or y < 1 or y > self.h then return end
    self.rows[y] = self.rows[y] or {}
    self.rows[y][x] = c
end

function Sub:filledRect(x, y, w, h, c)
    for j = y, y + h - 1 do
        for i = x, x + w - 1 do self:pixel(i, j, c) end
    end
end

function Sub:rect(x, y, w, h, c)
    for i = x, x + w - 1 do self:pixel(i, y, c); self:pixel(i, y + h - 1, c) end
    for j = y, y + h - 1 do self:pixel(x, j, c); self:pixel(x + w - 1, j, c) end
end

function Sub:line(x0, y0, x1, y1, c)
    -- Bresenham
    local dx = math.abs(x1 - x0); local sx = x0 < x1 and 1 or -1
    local dy = -math.abs(y1 - y0); local sy = y0 < y1 and 1 or -1
    local err = dx + dy
    while true do
        self:pixel(x0, y0, c)
        if x0 == x1 and y0 == y1 then break end
        local e2 = 2 * err
        if e2 >= dy then err = err + dy; x0 = x0 + sx end
        if e2 <= dx then err = err + dx; y0 = y0 + sy end
    end
end

-- Text is rendered at cell granularity (one cell = two pixel rows). The
-- y argument is in pixel coordinates; we floor to the nearest cell.
function Sub:text(x, py, str, fg)
    if not str or str == "" then return end
    local cy = math.floor((py - 1) / 2) + 1
    fg = fg or colors.white
    self.t.setCursorPos(x, cy)
    self.t.setTextColor(fg)
    self.t.setBackgroundColor(self.bg)
    self.t.write(str)
end

function Sub:flush()
    for cy = 1, self.ch do
        local top = self.rows[(cy - 1) * 2 + 1] or {}
        local bot = self.rows[(cy - 1) * 2 + 2] or {}
        local chars, fgs, bgs = {}, {}, {}
        for x = 1, self.cw do
            chars[#chars + 1] = HALF_BLOCK
            fgs[#fgs + 1]   = colorHex(top[x] or self.bg)
            bgs[#bgs + 1]   = colorHex(bot[x] or self.bg)
        end
        self.t.setCursorPos(1, cy)
        self.t.blit(table.concat(chars), table.concat(fgs), table.concat(bgs))
    end
end

return M
