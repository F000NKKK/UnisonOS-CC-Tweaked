-- unison.lib.gdi.shapes — drawing primitives extending Context.
--
-- Imported once during init.lua via `extend(Context)`. Adds rect /
-- fillRect / hLine / vLine / line / frame methods that all wrap their
-- calls in Context:with so pen/brush/cursor state is restored.

local M = {}

function M.extend(Context)
    function Context:fillRect(x, y, w, h, brush)
        if w < 1 or h < 1 then return end
        local line = string.rep(" ", w)
        self:with(function(ctx)
            if brush then ctx:setBrush(brush) end
            for j = 0, h - 1 do
                ctx:setCursor(x, y + j)
                ctx:_rawWrite(line)
            end
        end)
    end

    function Context:rect(x, y, w, h, pen)
        if w < 2 or h < 2 then return end
        self:with(function(ctx)
            if pen then ctx:setPen(pen) end
            local edge = "+" .. string.rep("-", w - 2) .. "+"
            ctx:setCursor(x, y);          ctx:_rawWrite(edge)
            ctx:setCursor(x, y + h - 1);  ctx:_rawWrite(edge)
            for i = 1, h - 2 do
                ctx:setCursor(x, y + i);          ctx:_rawWrite("|")
                ctx:setCursor(x + w - 1, y + i);  ctx:_rawWrite("|")
            end
        end)
    end

    function Context:hLine(x, y, w, ch, pen)
        if w < 1 then return end
        self:with(function(ctx)
            if pen then ctx:setPen(pen) end
            ctx:setCursor(x, y)
            ctx:_rawWrite(string.rep(ch or "-", w))
        end)
    end

    function Context:vLine(x, y, h, ch, pen)
        if h < 1 then return end
        self:with(function(ctx)
            if pen then ctx:setPen(pen) end
            for j = 0, h - 1 do
                ctx:setCursor(x, y + j)
                ctx:_rawWrite(ch or "|")
            end
        end)
    end

    -- Bresenham. Cells, not pixels — plot character is "*". For
    -- subpixel-accurate work use a Bitmap and blit.
    function Context:line(x0, y0, x1, y1, pen, ch)
        ch = ch or "*"
        self:with(function(ctx)
            if pen then ctx:setPen(pen) end
            local dx = math.abs(x1 - x0); local sx = x0 < x1 and 1 or -1
            local dy = -math.abs(y1 - y0); local sy = y0 < y1 and 1 or -1
            local err = dx + dy
            while true do
                ctx:setCursor(x0, y0); ctx:_rawWrite(ch)
                if x0 == x1 and y0 == y1 then break end
                local e2 = 2 * err
                if e2 >= dy then err = err + dy; x0 = x0 + sx end
                if e2 <= dx then err = err + dx; y0 = y0 + sy end
            end
        end)
    end

    function Context:frame(x, y, w, h, title, pen)
        self:rect(x, y, w, h, pen)
        if not (title and #title > 0) then return end
        self:with(function(ctx)
            if pen then ctx:setPen(pen) end
            local t = " " .. title .. " "
            if #t > w - 2 then t = t:sub(1, w - 2) end
            ctx:setCursor(x + math.floor((w - #t) / 2), y)
            ctx:_rawWrite(t)
        end)
    end
end

return M
