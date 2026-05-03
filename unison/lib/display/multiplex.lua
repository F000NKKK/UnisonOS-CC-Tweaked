-- unison.lib.display.multiplex — builds a term-redirect target that
-- writes through to the primary terminal AND mirrors every cell into
-- a Shadow (lib.display.shadow).
--
-- Apps see the primary terminal's coordinate system via getSize and
-- friends; mutations land on the Shadow so a separate flush loop can
-- repaint all monitors at its own cadence (delta-rendering, scaling).
--
-- Pure factory, no side effects: caller wires the returned multiplex
-- into term.redirect.

local Shadow = dofile("/unison/lib/display/shadow.lua")

local TERM_QUERY_PRIMARY = {
    "getCursorPos", "getCursorBlink",
    "getTextColor", "getTextColour",
    "getBackgroundColor", "getBackgroundColour",
    "isColor", "isColour",
    "getPaletteColor", "getPaletteColour",
    "getSize",
}

local M = {}

-- Returns { multiplex = <term-redirect target>, shadow = <Shadow>,
--           palette = <fn(...) to forward setPaletteColor everywhere> }
--
-- opts.shadowSize = { w, h } overrides the shadow's dimensions so a
-- larger monitor can drive a bigger virtual screen than the actual
-- primary terminal. multiplex.getSize then reports those dimensions
-- to apps so they render to fill the monitor.
function M.build(primary, monitors, opts)
    opts = opts or {}
    local pw, ph = primary.getSize()
    local sw, sh = pw, ph
    if opts.shadowSize and opts.shadowSize.w and opts.shadowSize.h then
        sw, sh = opts.shadowSize.w, opts.shadowSize.h
    end
    local shadow = Shadow.new(sw, sh)

    -- Sync initial cursor + pen so the shadow agrees with the screen
    -- straight after the first redirect.
    local ok, x, y = pcall(primary.getCursorPos)
    if ok then shadow.cx = x; shadow.cy = y end
    shadow.fg = primary.getTextColor and primary.getTextColor() or colors.white
    shadow.bg = primary.getBackgroundColor and primary.getBackgroundColor() or colors.black

    local m = {}

    function m.write(s)
        Shadow.write(shadow, s); pcall(primary.write, s)
    end
    function m.blit(text, fgs, bgs)
        Shadow.blit(shadow, text, fgs, bgs)
        pcall(primary.blit, text, fgs, bgs)
    end
    function m.clear()    Shadow.clear(shadow);     pcall(primary.clear) end
    function m.clearLine()Shadow.clearLine(shadow); pcall(primary.clearLine) end
    function m.scroll(n)  Shadow.scroll(shadow, n); pcall(primary.scroll, n) end

    function m.setCursorPos(x, y)
        Shadow.setCursorPos(shadow, x, y)
        pcall(primary.setCursorPos, x, y)
    end
    function m.setCursorBlink(b) pcall(primary.setCursorBlink, b) end

    function m.setTextColor(c)       Shadow.setFg(shadow, c); pcall(primary.setTextColor, c) end
    m.setTextColour = m.setTextColor
    function m.setBackgroundColor(c) Shadow.setBg(shadow, c); pcall(primary.setBackgroundColor, c) end
    m.setBackgroundColour = m.setBackgroundColor

    -- Palette changes need to reach every output (monitor renderers
    -- read the same palette indices). Forward to primary + every mon.
    function m.setPaletteColor(...)
        pcall(primary.setPaletteColor, ...)
        for _, mon in ipairs(monitors or {}) do
            pcall(mon.setPaletteColor, ...)
        end
    end
    m.setPaletteColour = m.setPaletteColor

    -- Pure passthrough for queries — apps see the primary's geometry.
    for _, fn in ipairs(TERM_QUERY_PRIMARY) do
        m[fn] = function(...) if primary[fn] then return primary[fn](...) end end
    end

    -- If the shadow was resized to a monitor, override getSize so apps
    -- render to the larger surface. Other queries still go to primary.
    if sw ~= pw or sh ~= ph then
        m.getSize = function() return sw, sh end
    end

    -- term.redirect compatibility: apps that call term.redirect(<target>)
    -- on us must get the previous redirect target back; CC's stock term
    -- does that for us when redirected, but a multiplex may also be the
    -- final target so we identity-return.
    m.redirect = function(target) return target end

    return { multiplex = m, shadow = shadow }
end

return M
