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
-- The caller still owns the monitor list; this factory only knows
-- about the primary terminal.
function M.build(primary, monitors)
    local pw, ph = primary.getSize()
    local shadow = Shadow.new(pw, ph)

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

    -- term.redirect compatibility: apps that call term.redirect(<target>)
    -- on us must get the previous redirect target back; CC's stock term
    -- does that for us when redirected, but a multiplex may also be the
    -- final target so we identity-return.
    m.redirect = function(target) return target end

    return { multiplex = m, shadow = shadow }
end

return M
