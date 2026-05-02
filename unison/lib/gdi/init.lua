-- unison.lib.gdi — graphics primitives over a term-target.
--
-- Public surface:
--   gdi.screen()             -> Context bound to term.current()
--                                (= the display multiplex once display
--                                has started)
--   gdi.fromTarget(t)        -> Context bound to any term-like target
--   gdi.bitmap(w, h, opts)   -> off-screen cell buffer (vertex/back
--                                buffer); .target() / .context() /
--                                .blitTo(dstCtx, x, y)
--   gdi.bitBlt(src, dst, x, y)  same blit but as a free function
--
-- Context methods (extended by shapes.lua + text.lua):
--   :size, :cursor, :setCursor
--   :setPen / :setBrush / :getPen / :getBrush / :isColor
--   :save / :restore / :with(fn)
--   :fillRect / :rect / :hLine / :vLine / :line / :frame
--   :drawText / :drawTextRect / :drawBlit / :measureText
--
-- GDI is intentionally separate from `lib/display` (which manages
-- physical monitors) and from `lib/stdio` (which is the text-IO entry
-- point). Both stdio and gdi end up writing through the same active
-- term-target, so a stdio:print and a gdi:drawText land in the same
-- multiplex Shadow → physical monitors.

local ContextMod = dofile("/unison/lib/gdi/context.lua")
local BitmapMod  = dofile("/unison/lib/gdi/bitmap.lua")
local BlitMod    = dofile("/unison/lib/gdi/blit.lua")

dofile("/unison/lib/gdi/shapes.lua").extend(ContextMod.Context)
dofile("/unison/lib/gdi/text.lua").extend(ContextMod.Context)

local M = {}

function M.fromTarget(t) return ContextMod.new(t) end
function M.screen()      return ContextMod.new(term.current()) end

function M.bitmap(w, h, opts)
    local bmp = BitmapMod.new(w, h, opts)
    -- Convenience: bmp:context() returns a Context drawing into bmp.
    function bmp:context() return ContextMod.new(self:target()) end
    return bmp
end

M.bitBlt  = BlitMod.bitBlt
M.Context = ContextMod.Context
M.Bitmap  = BitmapMod.Bitmap

return M
