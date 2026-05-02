-- unison.lib.gdi.text — text drawing on top of Context.
--
-- CC has exactly one font (built into the engine), so "fonts" boils
-- down to colour and wrap behaviour. drawText / drawTextRect / measure
-- / wrap live here; richer text needs gdi.bitmap + a custom blitter.

local M = {}

local function splitLines(s)
    -- gmatch with [^\r\n]* yields a trailing empty string, filter it.
    local out = {}
    for line in tostring(s):gmatch("([^\r\n]*)\r?\n?") do
        if not (line == "" and #out > 0 and out[#out] == "") then
            out[#out + 1] = line
        end
    end
    if #out > 0 and out[#out] == "" then out[#out] = nil end
    return out
end

function M.extend(Context)
    function Context:drawText(x, y, str, pen, brush)
        if not str or str == "" then return end
        self:with(function(ctx)
            if pen   then ctx:setPen(pen) end
            if brush then ctx:setBrush(brush) end
            ctx:setCursor(x, y)
            ctx:_rawWrite(str)
        end)
    end

    function Context:drawBlit(x, y, text, fgs, bgs)
        if not text or text == "" then return end
        self:with(function(ctx)
            ctx:setCursor(x, y)
            ctx:_rawBlit(text, fgs, bgs)
        end)
    end

    -- Draw `str` clipped to a w x h box at (x, y). Wraps on width,
    -- truncates on height. Honors embedded \n.
    function Context:drawTextRect(x, y, w, h, str, pen, brush)
        if not str or w < 1 or h < 1 then return end
        self:with(function(ctx)
            if pen   then ctx:setPen(pen) end
            if brush then ctx:setBrush(brush) end
            local row = 0
            for _, line in ipairs(splitLines(str)) do
                while #line > 0 and row < h do
                    local piece = line:sub(1, w)
                    ctx:setCursor(x, y + row)
                    ctx:_rawWrite(piece)
                    line = line:sub(w + 1)
                    row = row + 1
                end
                if row >= h then return end
                if line == "" then row = row + 1 end
            end
        end)
    end

    -- Cell-grid only has one font, so width == #string. Returns w, h.
    function Context:measureText(str, wrapWidth)
        if not str or str == "" then return 0, 0 end
        local lines = splitLines(str)
        if not wrapWidth then
            local maxW = 0
            for _, l in ipairs(lines) do if #l > maxW then maxW = #l end end
            return maxW, #lines
        end
        local h = 0
        for _, l in ipairs(lines) do
            h = h + math.max(1, math.ceil(#l / wrapWidth))
        end
        return math.min(wrapWidth, (function()
            local m = 0
            for _, l in ipairs(lines) do
                m = math.max(m, math.min(#l, wrapWidth))
            end
            return m
        end)()), h
    end
end

return M
