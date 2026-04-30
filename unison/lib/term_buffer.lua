-- unison.lib.term_buffer — wraps a CC term target and shadows every cell
-- write so we can broadcast the current screen state. Used by the
-- termsync service to mirror a device's terminal to the web console.

local M = {}

-- CC colour bitmasks → 0..15 index. We send the index over the bus.
local function colorIndex(c)
    if not c or c == 0 then return 0 end
    local i = 0
    while c > 1 do c = c / 2; i = i + 1 end
    return math.floor(i)
end

local FORWARD = {
    "setCursorBlink", "scroll", "setPaletteColor", "setPaletteColour",
    "getPaletteColor", "getPaletteColour",
}

function M.create(parent)
    local w, h = parent.getSize()
    local cells = {}
    local cur = {
        x = 1, y = 1,
        fg = parent.getTextColor and parent.getTextColor() or colors.white,
        bg = parent.getBackgroundColor and parent.getBackgroundColor() or colors.black,
    }

    for y = 1, h do
        cells[y] = {}
        for x = 1, w do cells[y][x] = { ch = " ", fg = cur.fg, bg = cur.bg } end
    end

    local function fillLine(y, fg, bg)
        for x = 1, w do cells[y][x] = { ch = " ", fg = fg, bg = bg } end
    end

    local function setAt(x, y, ch, fg, bg)
        if x < 1 or x > w or y < 1 or y > h then return end
        cells[y][x] = { ch = ch, fg = fg, bg = bg }
    end

    local function writeStr(str, fg, bg)
        str = tostring(str)
        for i = 1, #str do
            setAt(cur.x + i - 1, cur.y, str:sub(i, i), fg, bg)
        end
        cur.x = cur.x + #str
    end

    local t = {}

    for _, m in ipairs(FORWARD) do
        t[m] = function(...) if parent[m] then return parent[m](...) end end
    end

    function t.write(str)
        writeStr(tostring(str), cur.fg, cur.bg)
        return parent.write(str)
    end

    function t.blit(text, fg, bg)
        for i = 1, #text do
            local f = tonumber(fg:sub(i, i), 16) or 0
            local b = tonumber(bg:sub(i, i), 16) or 0
            setAt(cur.x + i - 1, cur.y, text:sub(i, i), 2 ^ f, 2 ^ b)
        end
        cur.x = cur.x + #text
        return parent.blit(text, fg, bg)
    end

    function t.clear()
        for y = 1, h do fillLine(y, cur.fg, cur.bg) end
        return parent.clear()
    end

    function t.clearLine()
        if cur.y >= 1 and cur.y <= h then fillLine(cur.y, cur.fg, cur.bg) end
        return parent.clearLine()
    end

    function t.setCursorPos(x, y) cur.x, cur.y = x, y; return parent.setCursorPos(x, y) end
    function t.getCursorPos() return cur.x, cur.y end
    function t.getSize() return w, h end

    local function color(setName, getName, field)
        t[setName] = function(c) cur[field] = c; return parent[setName] and parent[setName](c) end
        t[getName] = function() return cur[field] end
    end
    color("setTextColor",       "getTextColor",       "fg")
    color("setTextColour",      "getTextColour",      "fg")
    color("setBackgroundColor", "getBackgroundColor", "bg")
    color("setBackgroundColour","getBackgroundColour","bg")

    function t.isColor()  if parent.isColor  then return parent.isColor()  end; return true end
    function t.isColour() if parent.isColour then return parent.isColour() end; return t.isColor() end

    function t.redirect(target) return parent.redirect and parent.redirect(target) end

    -- Snapshot is a compact representation of the whole grid: w/h, cursor,
    -- and per-row { chars, fg, bg } where fg/bg are strings of hex digits
    -- (one char per cell), matching the format CC's term.blit uses.
    function t.snapshot()
        local rows = {}
        for y = 1, h do
            local cs, fg, bg = {}, {}, {}
            for x = 1, w do
                local c = cells[y][x]
                cs[x] = c.ch
                fg[x] = string.format("%x", colorIndex(c.fg))
                bg[x] = string.format("%x", colorIndex(c.bg))
            end
            rows[y] = {
                chars = table.concat(cs),
                fg    = table.concat(fg),
                bg    = table.concat(bg),
            }
        end
        return {
            w = w, h = h,
            cursor = { x = cur.x, y = cur.y,
                       fg = colorIndex(cur.fg), bg = colorIndex(cur.bg) },
            rows = rows,
        }
    end

    return t
end

return M
