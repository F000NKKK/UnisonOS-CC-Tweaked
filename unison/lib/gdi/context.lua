-- unison.lib.gdi.context — drawing context (DC) bound to a term-target.
--
-- A Context wraps anything that quacks like a terminal: term itself, a
-- window, a display multiplex, or a gdi.bitmap target. Every drawing
-- primitive on top (shapes / text / blit) calls into the same Context
-- methods, so the Context type is the single point through which every
-- drawing operation flows.
--
-- State held on the context: pen (text colour), brush (background) and
-- a save/restore stack so an op can scope its colour changes.
--
-- This module ONLY defines the class. The drawing primitives live in
-- shapes.lua / text.lua / blit.lua and extend the class. The full GDI
-- surface is assembled in init.lua.

local M = {}

local Context = {}
Context.__index = Context
M.Context = Context

local DEFAULT_FG = colors.white
local DEFAULT_BG = colors.black

function M.new(target)
    target = target or term.current()
    return setmetatable({
        t          = target,
        savedStack = {},
    }, Context)
end

function Context:target() return self.t end

function Context:size()
    if not self.t.getSize then return 51, 19 end
    return self.t.getSize()
end

function Context:cursor()
    if not self.t.getCursorPos then return 1, 1 end
    return self.t.getCursorPos()
end

function Context:setCursor(x, y)
    if self.t.setCursorPos then self.t.setCursorPos(x, y) end
end

function Context:setPen(c)
    if c and self.t.setTextColor then self.t.setTextColor(c) end
end

function Context:getPen()
    return self.t.getTextColor and self.t.getTextColor() or DEFAULT_FG
end

function Context:setBrush(c)
    if c and self.t.setBackgroundColor then self.t.setBackgroundColor(c) end
end

function Context:getBrush()
    return self.t.getBackgroundColor and self.t.getBackgroundColor() or DEFAULT_BG
end

function Context:isColor()
    if self.t.isColor then return self.t.isColor() end
    if self.t.isColour then return self.t.isColour() end
    return false
end

-- Push current pen/brush/cursor onto a stack so a primitive can mutate
-- them locally and roll back. Pair with :restore().
function Context:save()
    self.savedStack[#self.savedStack + 1] = {
        fg = self:getPen(),
        bg = self:getBrush(),
        cx = select(1, self:cursor()),
        cy = select(2, self:cursor()),
    }
end

function Context:restore()
    local s = table.remove(self.savedStack)
    if not s then return end
    self:setPen(s.fg)
    self:setBrush(s.bg)
    self:setCursor(s.cx, s.cy)
end

-- Convenience: run fn(self) between save/restore. Errors still roll
-- the state back.
function Context:with(fn)
    self:save()
    local ok, err = pcall(fn, self)
    self:restore()
    if not ok then error(err, 2) end
end

-- Raw write through the target. Apps shouldn't need this — use the
-- text.lua helpers — but shapes.lua relies on it for fill characters.
function Context:_rawWrite(s)
    if self.t.write then self.t.write(tostring(s or "")) end
end

function Context:_rawBlit(text, fgs, bgs)
    if self.t.blit then self.t.blit(text, fgs, bgs) end
end

return M
