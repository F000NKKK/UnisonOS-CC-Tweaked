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

-- ---- TextInput -----------------------------------------------------------

local TextInput = {}; TextInput.__index = TextInput
function M.textInput(opts)
    opts = opts or {}
    return setmetatable({
        text = opts.text or "",
        cursor = #(opts.text or "") + 1,
        placeholder = opts.placeholder or "",
        fg = opts.fg or colors.white,
        bg = opts.bg or colors.gray,
        cursorBg = opts.cursorBg or colors.yellow,
        max = opts.max,
        password = opts.password,
        onChange = opts.onChange,
        onSubmit = opts.onSubmit,
        focused = false,
    }, TextInput)
end
function TextInput:set(s)
    self.text = tostring(s or ""); self.cursor = #self.text + 1
    if self.onChange then self.onChange(self.text) end
end
function TextInput:render(buf, x, y, w, h)
    local shown = self.password and string.rep("\7", #self.text) or self.text
    local display = #shown == 0 and self.placeholder or shown
    if #display > w then display = display:sub(-w) end
    display = display .. string.rep(" ", w - #display)
    local fg = #shown == 0 and colors.gray or self.fg
    buf:text(x, y, display, fg, self.bg)
    if self.focused then
        local cx = math.min(w, self.cursor)
        local ch = display:sub(cx, cx)
        buf:text(x + cx - 1, y, ch == "" and " " or ch, self.fg, self.cursorBg)
    end
end
function TextInput:handleEvent(ev)
    local n = ev[1]
    if n == "char" then
        if self.max and #self.text >= self.max then return "consumed" end
        self.text = self.text:sub(1, self.cursor - 1) .. ev[2] .. self.text:sub(self.cursor)
        self.cursor = self.cursor + 1
        if self.onChange then self.onChange(self.text) end
        return "consumed"
    end
    if n == "key" then
        local k = ev[2]
        if k == keys.backspace and self.cursor > 1 then
            self.text = self.text:sub(1, self.cursor - 2) .. self.text:sub(self.cursor)
            self.cursor = self.cursor - 1
            if self.onChange then self.onChange(self.text) end
            return "consumed"
        end
        if k == keys.delete and self.cursor <= #self.text then
            self.text = self.text:sub(1, self.cursor - 1) .. self.text:sub(self.cursor + 1)
            if self.onChange then self.onChange(self.text) end
            return "consumed"
        end
        if k == keys.left  and self.cursor > 1                 then self.cursor = self.cursor - 1; return "consumed" end
        if k == keys.right and self.cursor <= #self.text       then self.cursor = self.cursor + 1; return "consumed" end
        if k == keys.home  then self.cursor = 1;                  return "consumed" end
        if k == keys["end"]then self.cursor = #self.text + 1;     return "consumed" end
        if k == keys.enter and self.onSubmit then self.onSubmit(self.text); return "consumed" end
    end
    if n == "paste" then
        local add = ev[2] or ""
        self.text = self.text:sub(1, self.cursor - 1) .. add .. self.text:sub(self.cursor)
        self.cursor = self.cursor + #add
        if self.max then self.text = self.text:sub(1, self.max) end
        if self.onChange then self.onChange(self.text) end
        return "consumed"
    end
end

-- ---- Table ---------------------------------------------------------------

local Table = {}; Table.__index = Table
function M.table(columns, rows, opts)
    opts = opts or {}
    return setmetatable({
        columns = columns or {},
        rows = rows or {},
        selected = 1,
        offset = 0,
        fg = opts.fg or colors.white,
        bg = opts.bg or colors.black,
        headFg = opts.headFg or colors.yellow,
        selFg = opts.selFg or colors.black,
        selBg = opts.selBg or colors.yellow,
        onSelect = opts.onSelect,
    }, Table)
end
function Table:setRows(rows)
    self.rows = rows or {}
    if self.selected > #self.rows then self.selected = math.max(1, #self.rows) end
end
function Table:formatRow(row, w)
    local parts = {}
    for _, col in ipairs(self.columns) do
        local v = row[col.key]
        local s = (v == nil) and "-" or tostring(v)
        local cw = col.w or 8
        if #s > cw then s = s:sub(1, cw) end
        parts[#parts + 1] = s .. string.rep(" ", cw - #s)
    end
    local line = table.concat(parts, " ")
    if #line > w then line = line:sub(1, w) end
    return line .. string.rep(" ", w - #line)
end
function Table:render(buf, x, y, w, h)
    local header = {}
    for _, col in ipairs(self.columns) do
        local label = col.label or col.key or "?"
        local cw = col.w or 8
        if #label > cw then label = label:sub(1, cw) end
        header[#header + 1] = label .. string.rep(" ", cw - #label)
    end
    local hline = table.concat(header, " ")
    if #hline > w then hline = hline:sub(1, w) end
    hline = hline .. string.rep(" ", w - #hline)
    buf:text(x, y, hline, self.headFg, self.bg)
    local bodyH = h - 1
    if bodyH < 1 then return end
    if self.selected < self.offset + 1 then self.offset = self.selected - 1 end
    if self.selected > self.offset + bodyH then self.offset = self.selected - bodyH end
    for i = 1, bodyH do
        local idx = i + self.offset
        local row = self.rows[idx]
        if row then
            local line = self:formatRow(row, w)
            if idx == self.selected then
                buf:text(x, y + i, line, self.selFg, self.selBg)
            else
                buf:text(x, y + i, line, self.fg, self.bg)
            end
        else
            buf:text(x, y + i, string.rep(" ", w), self.fg, self.bg)
        end
    end
end
function Table:handleEvent(ev)
    if ev[1] ~= "key" then return end
    local k = ev[2]
    if k == keys.up        then self.selected = math.max(1, self.selected - 1); return "consumed" end
    if k == keys.down      then self.selected = math.min(#self.rows, self.selected + 1); return "consumed" end
    if k == keys.pageUp    then self.selected = math.max(1, self.selected - 10); return "consumed" end
    if k == keys.pageDown  then self.selected = math.min(#self.rows, self.selected + 10); return "consumed" end
    if k == keys.home      then self.selected = 1; return "consumed" end
    if k == keys["end"]    then self.selected = #self.rows; return "consumed" end
    if k == keys.enter and self.onSelect then
        self.onSelect(self.rows[self.selected], self.selected); return "consumed"
    end
end

-- ---- Modal / Dialog ------------------------------------------------------

local Modal = {}; Modal.__index = Modal
function M.modal(opts)
    opts = opts or {}
    return setmetatable({
        title = opts.title or "",
        body = opts.body,
        buttons = opts.buttons or {},
        focusButton = 1,
        fg = opts.fg or colors.white,
        bg = opts.bg or colors.gray,
        borderFg = opts.borderFg or colors.lightGray,
    }, Modal)
end
function Modal:render(buf, x, y, w, h)
    local cw = math.min(w - 4, 60)
    local ch = math.min(h - 4, 12)
    local cx = x + math.floor((w - cw) / 2)
    local cy = y + math.floor((h - ch) / 2)
    buf:rect(x, y, w, h, " ", self.bg, colors.black)
    buf:box(cx, cy, cw, ch, self.borderFg, self.bg)
    buf:text(cx + 2, cy, " " .. self.title .. " ", self.fg, self.bg)
    if self.body and self.body.render then
        self.body:render(buf, cx + 2, cy + 2, cw - 4, ch - 5)
    end
    local by = cy + ch - 2
    local bx = cx + 2
    for i, b in ipairs(self.buttons) do
        local label = "[ " .. b.label .. " ]"
        local fg = (i == self.focusButton) and colors.black or self.fg
        local bg = (i == self.focusButton) and colors.yellow or self.bg
        buf:text(bx, by, label, fg, bg)
        bx = bx + #label + 1
    end
end
function Modal:handleEvent(ev)
    if self.body and self.body.handleEvent then
        local r = self.body:handleEvent(ev)
        if r == "consumed" then return r end
    end
    if ev[1] == "key" then
        local k = ev[2]
        if k == keys.tab then
            self.focusButton = (self.focusButton % math.max(1, #self.buttons)) + 1
            return "consumed"
        end
        if k == keys.enter and self.buttons[self.focusButton] then
            local b = self.buttons[self.focusButton]
            if b.onPress then b.onPress() end
            return "consumed"
        end
    end
end

-- ---- Layout helpers ------------------------------------------------------
-- Tiny grid splitter: divides a rect into rows or columns by ratio/abs.
-- Negative numbers are absolute sizes; positive are flex weights.
--   row({-3, 1, 1}, rect) → first column 3 wide, remaining split 1:1
M.layout = {}
function M.layout.row(specs, rect) return M.layout._split(specs, rect, "h") end
function M.layout.col(specs, rect) return M.layout._split(specs, rect, "v") end
function M.layout._split(specs, rect, dir)
    local total = (dir == "h") and rect.w or rect.h
    local fixed, flex = 0, 0
    for _, s in ipairs(specs) do
        if s < 0 then fixed = fixed + (-s) else flex = flex + s end
    end
    local remain = math.max(0, total - fixed)
    local out, pos = {}, 0
    for _, s in ipairs(specs) do
        local size = (s < 0) and (-s) or (flex > 0 and math.floor((s / flex) * remain) or 0)
        if dir == "h" then
            out[#out + 1] = { x = rect.x + pos, y = rect.y, w = size, h = rect.h }
        else
            out[#out + 1] = { x = rect.x, y = rect.y + pos, w = rect.w, h = size }
        end
        pos = pos + size
    end
    return out
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
