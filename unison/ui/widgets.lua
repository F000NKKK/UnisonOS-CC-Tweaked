-- Reusable widgets that draw onto a unison/ui/buffer.
--
-- Every widget is a constructor returning a table with a :render(buf, x, y, w, h)
-- method and (optionally) a :handleEvent(ev) method. They are intentionally
-- self-contained — no global state — so apps can compose them inside their
-- window's render fn.

local M = {}

-- ---- Label ---------------------------------------------------------------

local Label = {}; Label.__index = Label
function M.label(text, opts)
    opts = opts or {}
    return setmetatable({
        text = text or "",
        fg = opts.fg or colors.white,
        bg = opts.bg or colors.black,
        align = opts.align or "left",
    }, Label)
end
function Label:render(buf, x, y, w, h)
    local s = tostring(self.text)
    if #s > w then s = s:sub(1, w) end
    local px = x
    if self.align == "right" then px = x + w - #s
    elseif self.align == "center" then px = x + math.floor((w - #s) / 2) end
    buf:text(px, y, s, self.fg, self.bg)
end

-- ---- List (scrollable) ---------------------------------------------------

local List = {}; List.__index = List
function M.list(items, opts)
    opts = opts or {}
    return setmetatable({
        items = items or {},
        selected = 1,
        offset = 0,
        fg = opts.fg or colors.white,
        bg = opts.bg or colors.black,
        selFg = opts.selFg or colors.black,
        selBg = opts.selBg or colors.yellow,
        onSelect = opts.onSelect,
    }, List)
end
function List:setItems(items)
    self.items = items or {}
    if self.selected > #self.items then self.selected = math.max(1, #self.items) end
end
function List:render(buf, x, y, w, h)
    if self.selected < self.offset + 1 then self.offset = self.selected - 1 end
    if self.selected > self.offset + h then self.offset = self.selected - h end
    for i = 1, h do
        local idx = i + self.offset
        local item = self.items[idx]
        if item then
            local label = type(item) == "table" and (item.label or tostring(item)) or tostring(item)
            if #label > w then label = label:sub(1, w) end
            label = label .. string.rep(" ", w - #label)
            if idx == self.selected then
                buf:text(x, y + i - 1, label, self.selFg, self.selBg)
            else
                buf:text(x, y + i - 1, label, self.fg, self.bg)
            end
        else
            buf:text(x, y + i - 1, string.rep(" ", w), self.fg, self.bg)
        end
    end
end
function List:handleEvent(ev)
    if ev[1] ~= "key" then return end
    local k = ev[2]
    if k == keys.up then
        self.selected = math.max(1, self.selected - 1)
        return "consumed"
    end
    if k == keys.down then
        self.selected = math.min(#self.items, self.selected + 1)
        return "consumed"
    end
    if k == keys.enter and self.onSelect then
        self.onSelect(self.items[self.selected], self.selected)
        return "consumed"
    end
end

-- ---- Button --------------------------------------------------------------

local Button = {}; Button.__index = Button
function M.button(text, onPress, opts)
    opts = opts or {}
    return setmetatable({
        text = text,
        onPress = onPress,
        fg = opts.fg or colors.white,
        bg = opts.bg or colors.gray,
        focused = false,
    }, Button)
end
function Button:render(buf, x, y, w, h)
    local label = " " .. self.text .. " "
    if #label > w then label = label:sub(1, w) end
    label = label .. string.rep(" ", w - #label)
    local fg = self.focused and colors.black or self.fg
    local bg = self.focused and colors.yellow or self.bg
    buf:text(x, y, label, fg, bg)
end
function Button:handleEvent(ev)
    if ev[1] == "key" and (ev[2] == keys.enter or ev[2] == keys.space) then
        if self.onPress then self.onPress() end
        return "consumed"
    end
    if ev[1] == "mouse_click" then
        if self.onPress then self.onPress() end
        return "consumed"
    end
end

-- ---- Progress bar --------------------------------------------------------

local Progress = {}; Progress.__index = Progress
function M.progress(value, max, opts)
    opts = opts or {}
    return setmetatable({
        value = value or 0,
        max = max or 100,
        fg = opts.fg or colors.lime,
        bg = opts.bg or colors.gray,
        label = opts.label,
    }, Progress)
end
function Progress:set(v) self.value = v end
function Progress:render(buf, x, y, w, h)
    local pct = math.max(0, math.min(1, self.value / math.max(1, self.max)))
    local fillW = math.floor(pct * w)
    if fillW > 0 then buf:rect(x, y, fillW, h, " ", self.fg, self.fg) end
    if fillW < w then buf:rect(x + fillW, y, w - fillW, h, " ", self.bg, self.bg) end
    if self.label then
        local s = tostring(self.label) .. " " .. math.floor(pct * 100) .. "%"
        local cx = x + math.floor((w - #s) / 2)
        buf:text(cx, y, s, colors.white, colors.gray)
    end
end

return M
