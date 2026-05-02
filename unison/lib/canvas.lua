-- unison.lib.canvas — pixel-style drawing helpers.
--
-- Two modes:
--   M.cell(target)     -> a thin wrapper over the gdi shapes API (one
--                          pixel per terminal cell; correct for
--                          paintutils-style art)
--   M.subpixel(target) -> a virtual W x 2H buffer. Each cell shows two
--                          stacked sub-pixels using the half-block
--                          character; flush() blits the buffer to the
--                          target. Doubles vertical resolution.
--
-- Both expose: clear, pixel, line, rect (outline), filledRect, text.
-- Subpixel additionally has flush(), and its coords are 1..W, 1..(2H).
--
-- Cell mode is implemented on top of unison.lib.gdi; subpixel keeps its
-- own row-blit for speed (one blit per cell-row over the half-block
-- char). Both end up writing through the same active term-target.

local fmt = dofile("/unison/lib/fmt.lua")
local gdi = dofile("/unison/lib/gdi/init.lua")
local HALF_BLOCK = fmt.HALF_BLOCK
local function colorHex(c) return fmt.colorHex(c) end

local M = {}

----------------------------------------------------------------------
-- Cell-level (delegates to gdi)
----------------------------------------------------------------------

local Cell = {}; Cell.__index = Cell

function M.cell(target)
    target = target or term.current()
    local ctx = gdi.fromTarget(target)
    local w, h = ctx:size()
    return setmetatable({
        t   = target,
        ctx = ctx,
        w   = w, h = h,
    }, Cell)
end

function Cell:size() return self.w, self.h end

function Cell:clear(c)
    self.ctx:fillRect(1, 1, self.w, self.h, c or colors.black)
    self.ctx:setCursor(1, 1)
end

function Cell:pixel(x, y, c)
    self.ctx:fillRect(x, y, 1, 1, c)
end

function Cell:line(x1, y1, x2, y2, c)
    -- Cell-grain line via gdi (Bresenham, character "*" by default).
    -- Use a space with brush=c to draw "filled" pixels — matches the
    -- previous paintutils behaviour where a line set the *background*
    -- colour of each cell.
    self.ctx:with(function(ctx)
        if c then ctx:setBrush(c) end
        local dx = math.abs(x2 - x1); local sx = x1 < x2 and 1 or -1
        local dy = -math.abs(y2 - y1); local sy = y1 < y2 and 1 or -1
        local err = dx + dy
        while true do
            ctx:setCursor(x1, y1); ctx:_rawWrite(" ")
            if x1 == x2 and y1 == y2 then break end
            local e2 = 2 * err
            if e2 >= dy then err = err + dy; x1 = x1 + sx end
            if e2 <= dx then err = err + dx; y1 = y1 + sy end
        end
    end)
end

function Cell:rect(x1, y1, x2, y2, c)
    -- Outline: top + bottom rows, left + right columns, one cell thick.
    local x = math.min(x1, x2); local y = math.min(y1, y2)
    local w = math.abs(x2 - x1) + 1
    local h = math.abs(y2 - y1) + 1
    self.ctx:with(function(ctx)
        if c then ctx:setBrush(c) end
        ctx:setCursor(x, y);          ctx:_rawWrite(string.rep(" ", w))
        ctx:setCursor(x, y + h - 1);  ctx:_rawWrite(string.rep(" ", w))
        for j = 1, h - 2 do
            ctx:setCursor(x, y + j);          ctx:_rawWrite(" ")
            ctx:setCursor(x + w - 1, y + j);  ctx:_rawWrite(" ")
        end
    end)
end

function Cell:filledRect(x1, y1, x2, y2, c)
    local x = math.min(x1, x2); local y = math.min(y1, y2)
    local w = math.abs(x2 - x1) + 1
    local h = math.abs(y2 - y1) + 1
    self.ctx:fillRect(x, y, w, h, c)
end

function Cell:text(x, y, str, fg, bg)
    self.ctx:drawText(x, y, str or "", fg, bg)
end

----------------------------------------------------------------------
-- Sub-pixel buffer (2x vertical resolution via the half-block char)
--
-- Kept as a hand-rolled blit because each cell-row collapses two
-- sub-pixel rows into one half-block blit — the whole point is the
-- batched .blit() per cell-row, which a generic gdi path can't match.
----------------------------------------------------------------------

local Sub = {}; Sub.__index = Sub

function M.subpixel(target)
    target = target or term.current()
    local cw, ch = target.getSize()
    local self = setmetatable({
        t   = target,
        cw  = cw, ch = ch,
        w   = cw, h  = ch * 2,
        bg  = colors.black,
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

-- Text is rendered at cell granularity (one cell = two pixel rows).
-- The y argument is in pixel coordinates; we floor to the nearest cell.
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
