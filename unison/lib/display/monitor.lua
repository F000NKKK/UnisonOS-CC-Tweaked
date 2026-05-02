-- unison.lib.display.monitor — paint a Shadow onto a single monitor
-- peripheral with delta-rendering.
--
-- Strategy:
--   - Compute centred letterbox offset between the shadow and the
--     monitor's own getSize.
--   - For each visible row, build the (chars, fgs, bgs) blit triple.
--   - Compare against the previous-frame triple cached per-monitor;
--     only setCursorPos+blit rows that actually changed.
--   - When the monitor's dimensions change, force a full repaint.
--
-- A full-screen redraw on a fresh CC-Tweaked monitor is dirt cheap
-- (one blit per row). The win shows up once the screen is mostly
-- static — e.g. the desktop launcher with 6 idle apps was previously
-- pushing 600 cell-blits per tick × 4 monitors at 20 Hz = 48k ops/s
-- of pure ceremony. Now: 0 ops/s when nothing changes.

local fmt = dofile("/unison/lib/fmt.lua")

local M = {}

-- Per-monitor cache key. Keyed by side string so reattaches reset state.
function M.newCache() return {} end

local function letterbox(shadowW, shadowH, mw, mh)
    local offX = math.floor((mw - shadowW) / 2)
    local offY = math.floor((mh - shadowH) / 2)
    return offX, offY
end

-- Build the (chars, fgs, bgs) triple for one shadow-row trimmed to
-- the visible monitor span. Returns nil, nil, nil, nil for off-screen
-- rows — caller skips them.
local function buildRow(shadow, sy, mw, offX)
    local row = shadow.cells[sy]
    local sx0 = 1
    local mx0 = offX + 1
    if mx0 < 1 then sx0 = 1 - offX; mx0 = 1 end
    local sx1 = shadow.w
    if mx0 + (sx1 - sx0) > mw then sx1 = sx0 + (mw - mx0) end
    if sx1 < sx0 then return nil end

    local n = sx1 - sx0 + 1
    local chars, fgs, bgs = table.create and table.create(n) or {},
                            table.create and table.create(n) or {},
                            table.create and table.create(n) or {}
    for i = 1, n do
        local cell = row[sx0 + i - 1]
        chars[i] = cell.ch
        fgs[i]   = fmt.HEX[cell.fg] or "0"
        bgs[i]   = fmt.HEX[cell.bg] or "f"
    end
    return mx0, table.concat(chars), table.concat(fgs), table.concat(bgs)
end

-- Paint shadow → mon, using `cache` to skip unchanged rows. Returns
-- nothing; mutates the cache entry. `cacheKey` is whatever the caller
-- uses to identify this monitor (peripheral side or name).
function M.paint(shadow, mon, cache, cacheKey)
    local ok, mw, mh = pcall(mon.getSize)
    if not ok or not mw or mw < 1 or mh < 1 then return end

    local entry = cache[cacheKey]
    -- Reset cache + clear monitor on size / version-skipped changes.
    if (not entry) or entry.w ~= mw or entry.h ~= mh then
        pcall(mon.setBackgroundColor, colors.black)
        pcall(mon.clear)
        entry = { w = mw, h = mh, rows = {} }
        cache[cacheKey] = entry
    end

    local offX, offY = letterbox(shadow.w, shadow.h, mw, mh)
    for sy = 1, shadow.h do
        local my = sy + offY
        if my >= 1 and my <= mh then
            local mx0, chars, fgs, bgs = buildRow(shadow, sy, mw, offX)
            if mx0 then
                local prev = entry.rows[my]
                if (not prev) or prev.chars ~= chars
                              or prev.fgs   ~= fgs
                              or prev.bgs   ~= bgs then
                    pcall(mon.setCursorPos, mx0, my)
                    pcall(mon.blit, chars, fgs, bgs)
                    entry.rows[my] = { chars = chars, fgs = fgs, bgs = bgs }
                end
            end
        end
    end
end

-- Reverse the letterbox offset for monitor_touch coordinates. Returns
-- (sx, sy) in shadow coords, or nil if the click landed on padding.
function M.touchToShadow(shadow, mw, mh, mx, my)
    local offX, offY = letterbox(shadow.w, shadow.h, mw, mh)
    local sx = mx - offX
    local sy = my - offY
    if sx >= 1 and sx <= shadow.w and sy >= 1 and sy <= shadow.h then
        return sx, sy
    end
    return nil
end

return M
