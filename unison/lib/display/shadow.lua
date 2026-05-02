-- unison.lib.display.shadow — pure cell grid with cursor + pen state.
--
-- The display multiplex maintains a Shadow sized to the primary
-- terminal. Every term op (write/blit/clear/scroll/setColor) mutates
-- both the primary terminal and the Shadow; monitor painters read the
-- Shadow back. Keeping it a self-contained module makes the multiplex
-- a small wrapper and lets monitor renderers be tested independently.
--
-- Each cell = { ch, fg, bg }. Coordinates are 1-indexed.

local M = {}

local function newCell(ch, fg, bg) return { ch = ch, fg = fg, bg = bg } end

function M.new(w, h)
    local cells = {}
    for y = 1, h do
        cells[y] = {}
        for x = 1, w do
            cells[y][x] = newCell(" ", colors.white, colors.black)
        end
    end
    return setmetatable({
        w = w, h = h,
        cells = cells,
        cx = 1, cy = 1,
        fg = colors.white, bg = colors.black,
        version = 0,            -- bumped on every mutation; consumers
                                -- can short-circuit when unchanged.
    }, { __index = M })
end

local function bump(sh) sh.version = sh.version + 1 end

function M.set(sh, x, y, ch, fg, bg)
    if y < 1 or y > sh.h or x < 1 or x > sh.w then return end
    local row = sh.cells[y]; if not row then return end
    local cell = row[x]
    cell.ch = ch; cell.fg = fg; cell.bg = bg
    bump(sh)
end

function M.write(sh, s)
    s = tostring(s or "")
    for i = 1, #s do
        M.set(sh, sh.cx + i - 1, sh.cy, s:sub(i, i), sh.fg, sh.bg)
    end
    sh.cx = sh.cx + #s
end

function M.blit(sh, text, fgs, bgs)
    for i = 1, #text do
        local f = tonumber(fgs:sub(i, i), 16) or 0
        local b = tonumber(bgs:sub(i, i), 16) or 15
        M.set(sh, sh.cx + i - 1, sh.cy, text:sub(i, i), 2 ^ f, 2 ^ b)
    end
    sh.cx = sh.cx + #text
end

function M.clear(sh)
    for y = 1, sh.h do
        for x = 1, sh.w do
            local c = sh.cells[y][x]
            c.ch = " "; c.fg = sh.fg; c.bg = sh.bg
        end
    end
    bump(sh)
end

function M.clearLine(sh)
    if sh.cy < 1 or sh.cy > sh.h then return end
    for x = 1, sh.w do
        local c = sh.cells[sh.cy][x]
        c.ch = " "; c.fg = sh.fg; c.bg = sh.bg
    end
    bump(sh)
end

-- Positive n: scroll up (rows shift toward y=1, bottom rows become
-- blank). Negative n: scroll down. Reuses row tables to avoid per-cell
-- re-allocation in the common case.
function M.scroll(sh, n)
    n = tonumber(n) or 0
    if n == 0 then return end
    local function blankRow()
        local row = {}
        for x = 1, sh.w do row[x] = newCell(" ", sh.fg, sh.bg) end
        return row
    end
    if n > 0 then
        for y = 1, sh.h do
            local src = y + n
            sh.cells[y] = (src <= sh.h) and sh.cells[src] or blankRow()
        end
    else
        for y = sh.h, 1, -1 do
            local src = y + n
            sh.cells[y] = (src >= 1) and sh.cells[src] or blankRow()
        end
    end
    bump(sh)
end

function M.setCursorPos(sh, x, y) sh.cx = x; sh.cy = y end
function M.setFg(sh, c) sh.fg = c end
function M.setBg(sh, c) sh.bg = c end

return M
