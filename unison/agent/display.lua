-- High-level отрисовка: __display.text/bar/chart/clear.
-- monitor может быть peripheral name (например "monitor_1") или nil → term.

local M = { specials = {} }

local function getCanvas(name)
    if not name or name == "" then return term end
    local p = peripheral.wrap(name)
    if not p then error("no peripheral '" .. name .. "'") end
    return p
end

local function setIfNumber(canvas, fn, v)
    if v and v ~= 0 then canvas[fn](canvas, v) end
end

M.specials["__display.clear"] = function(monitor, bg)
    local c = getCanvas(monitor)
    if bg and c.setBackgroundColor then c.setBackgroundColor(bg) end
    c.clear()
    if c.setCursorPos then c.setCursorPos(1, 1) end
    return true
end

M.specials["__display.text"] = function(monitor, x, y, text, fg, bg, scale)
    local c = getCanvas(monitor)
    if scale and scale > 0 and c.setTextScale then c.setTextScale(scale) end
    if fg and c.setTextColor then c.setTextColor(fg) end
    if bg and c.setBackgroundColor then c.setBackgroundColor(bg) end
    c.setCursorPos(x or 1, y or 1)
    c.write(text or "")
    return true
end

M.specials["__display.bar"] = function(monitor, x, y, width, fraction, fillColor, emptyColor, label)
    local c = getCanvas(monitor)
    width = math.max(1, math.floor(width or 10))
    fraction = math.max(0, math.min(1, fraction or 0))
    local filled = math.floor(width * fraction + 0.5)
    if c.setBackgroundColor and fillColor  then c.setBackgroundColor(fillColor) end
    c.setCursorPos(x, y)
    if filled > 0 then c.write(string.rep(" ", filled)) end
    if c.setBackgroundColor and emptyColor then c.setBackgroundColor(emptyColor) end
    if width - filled > 0 then c.write(string.rep(" ", width - filled)) end
    if label and label ~= "" then
        if c.setBackgroundColor and emptyColor then c.setBackgroundColor(emptyColor) end
        c.setCursorPos(x, y)
        c.write(label:sub(1, width))
    end
    return true
end

M.specials["__display.chart"] = function(monitor, x, y, width, height, values, lineColor, bg, vmin, vmax)
    local c = getCanvas(monitor)
    width = math.max(1, math.floor(width or 20))
    height = math.max(1, math.floor(height or 5))
    values = values or {}
    if vmin == vmax then
        vmin, vmax = math.huge, -math.huge
        for _, v in ipairs(values) do
            if v < vmin then vmin = v end
            if v > vmax then vmax = v end
        end
        if vmin == math.huge then vmin, vmax = 0, 1 end
        if vmin == vmax then vmax = vmin + 1 end
    end
    -- очистить bbox
    if c.setBackgroundColor and bg then c.setBackgroundColor(bg) end
    for row = 0, height - 1 do
        c.setCursorPos(x, y + row)
        c.write(string.rep(" ", width))
    end
    if #values == 0 then return true end
    -- семплируем values на width столбцов, ставим '#'
    if c.setBackgroundColor and lineColor then c.setBackgroundColor(lineColor) end
    for col = 0, width - 1 do
        local idx = math.floor(col * #values / width) + 1
        local v = values[idx] or vmin
        local norm = (v - vmin) / (vmax - vmin)
        local h = math.floor(norm * (height - 1) + 0.5)
        c.setCursorPos(x + col, y + (height - 1) - h)
        c.write(" ")
    end
    return true
end

return M
