-- unison.lib.gdi.blit — copy a Bitmap onto a Context.
--
-- One blit() call per row. Skips out-of-bounds pixels on the dst side
-- by clipping the row span to the dst Context's reported size.

local fmt = dofile("/unison/lib/fmt.lua")

local M = {}

local function hex(c) return fmt.HEX[c] or "0" end

-- Copy `src` (Bitmap) into `dstCtx` (Context) at (dstX, dstY) in dst
-- cell coordinates. Pixels outside dst are clipped silently.
function M.bitBlt(src, dstCtx, dstX, dstY)
    if not (src and dstCtx) then return end
    dstX = dstX or 1; dstY = dstY or 1
    local dw, dh = dstCtx:size()
    local target = dstCtx:target()
    if not (target and target.setCursorPos and target.blit) then return end

    for sy = 1, src.h do
        local dy = dstY + sy - 1
        if dy >= 1 and dy <= dh then
            -- Clip src x-span against dst.
            local sx0, dx0 = 1, dstX
            if dx0 < 1 then sx0 = 1 - dx0 + 1; dx0 = 1 end
            local sx1 = src.w
            if dx0 + (sx1 - sx0) > dw then sx1 = sx0 + (dw - dx0) end
            if sx1 >= sx0 then
                local row = src.cells[sy]
                local n = sx1 - sx0 + 1
                local chars, fgs, bgs = {}, {}, {}
                for i = 1, n do
                    local c = row[sx0 + i - 1]
                    chars[i] = c.ch
                    fgs[i]   = hex(c.fg)
                    bgs[i]   = hex(c.bg)
                end
                pcall(target.setCursorPos, dx0, dy)
                pcall(target.blit, table.concat(chars), table.concat(fgs), table.concat(bgs))
            end
        end
    end
end

return M
