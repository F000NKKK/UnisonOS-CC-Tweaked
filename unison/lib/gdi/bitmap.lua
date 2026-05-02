-- unison.lib.gdi.bitmap — off-screen cell grid that quacks like a
-- terminal target.
--
-- A Bitmap is the GDI equivalent of a vertex/back buffer: an in-memory
-- grid of { ch, fg, bg } cells you can draw into using the same Context
-- API as the screen. Rendering is decoupled from presentation — call
-- gdi.bitBlt(bitmap, dstCtx, x, y) (or bitmap:blitTo(...)) once you're
-- ready to push the buffer onto a real Context.
--
-- Implementation note: Bitmap:target() returns a fake term-target. Pass
-- it to Context.new() and every shapes/text method works against the
-- bitmap exactly as if it were the screen.

local M = {}

local Bitmap = {}
Bitmap.__index = Bitmap
M.Bitmap = Bitmap

local function newCell(ch, fg, bg) return { ch = ch, fg = fg, bg = bg } end

local function blankRow(w, fg, bg)
    local r = {}
    for x = 1, w do r[x] = newCell(" ", fg, bg) end
    return r
end

function M.new(w, h, opts)
    opts = opts or {}
    local fg = opts.fg or colors.white
    local bg = opts.bg or colors.black
    local cells = {}
    for y = 1, h do cells[y] = blankRow(w, fg, bg) end
    return setmetatable({
        w = w, h = h,
        cells = cells,
        cx = 1, cy = 1,
        fg = fg, bg = bg,
    }, Bitmap)
end

function Bitmap:size() return self.w, self.h end

local function cellAt(self, x, y)
    if x < 1 or x > self.w or y < 1 or y > self.h then return nil end
    return self.cells[y][x]
end

-- Build a term-target view of this bitmap. Methods mutate the cell
-- grid; readers report stored state. `target.blit` exists so MonRender-
-- and Context-style code paths Just Work.
function Bitmap:target()
    local self_ = self
    return {
        getSize = function() return self_.w, self_.h end,
        getCursorPos = function() return self_.cx, self_.cy end,
        setCursorPos = function(x, y) self_.cx, self_.cy = x, y end,
        getCursorBlink = function() return false end,
        setCursorBlink = function() end,
        getTextColor       = function() return self_.fg end,
        getTextColour      = function() return self_.fg end,
        setTextColor       = function(c) self_.fg = c end,
        setTextColour      = function(c) self_.fg = c end,
        getBackgroundColor = function() return self_.bg end,
        getBackgroundColour= function() return self_.bg end,
        setBackgroundColor = function(c) self_.bg = c end,
        setBackgroundColour= function(c) self_.bg = c end,
        isColor  = function() return true end,
        isColour = function() return true end,
        write = function(s)
            s = tostring(s or "")
            for i = 1, #s do
                local c = cellAt(self_, self_.cx + i - 1, self_.cy)
                if c then c.ch, c.fg, c.bg = s:sub(i, i), self_.fg, self_.bg end
            end
            self_.cx = self_.cx + #s
        end,
        blit = function(text, fgs, bgs)
            for i = 1, #text do
                local c = cellAt(self_, self_.cx + i - 1, self_.cy)
                local f = tonumber(fgs:sub(i, i), 16) or 0
                local b = tonumber(bgs:sub(i, i), 16) or 15
                if c then c.ch, c.fg, c.bg = text:sub(i, i), 2 ^ f, 2 ^ b end
            end
            self_.cx = self_.cx + #text
        end,
        clear = function()
            for y = 1, self_.h do
                for x = 1, self_.w do
                    local c = self_.cells[y][x]
                    c.ch = " "; c.fg = self_.fg; c.bg = self_.bg
                end
            end
        end,
        clearLine = function()
            local row = self_.cells[self_.cy]; if not row then return end
            for x = 1, self_.w do
                local c = row[x]; c.ch = " "; c.fg = self_.fg; c.bg = self_.bg
            end
        end,
        scroll = function(n)
            n = tonumber(n) or 0
            if n == 0 then return end
            if n > 0 then
                for y = 1, self_.h do
                    local src = y + n
                    self_.cells[y] = (src <= self_.h) and self_.cells[src]
                                  or blankRow(self_.w, self_.fg, self_.bg)
                end
            else
                for y = self_.h, 1, -1 do
                    local src = y + n
                    self_.cells[y] = (src >= 1) and self_.cells[src]
                                  or blankRow(self_.w, self_.fg, self_.bg)
                end
            end
        end,
    }
end

-- Fast clear without going through the target shim.
function Bitmap:clear(fg, bg)
    self.fg = fg or self.fg
    self.bg = bg or self.bg
    for y = 1, self.h do
        for x = 1, self.w do
            local c = self.cells[y][x]
            c.ch = " "; c.fg = self.fg; c.bg = self.bg
        end
    end
    self.cx, self.cy = 1, 1
end

-- Resolve the lazy import of blit on first use to avoid a circular
-- require chain at load time.
local _blit
function Bitmap:blitTo(dstCtx, x, y)
    if not _blit then _blit = dofile("/unison/lib/gdi/blit.lua") end
    _blit.bitBlt(self, dstCtx, x, y)
end

return M
