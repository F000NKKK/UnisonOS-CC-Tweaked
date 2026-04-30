-- sysmon — small TUI dashboard built on the UniAPI (unison.ui + unison.lib).

local wm      = unison.ui.wm
local widgets = unison.ui.widgets
local fsLib   = unison.lib.fs
local fmt     = unison.lib.fmt

local LOG_FILE = "/unison/logs/current.log"

local function readServices()
    local svc = unison and unison.kernel and unison.kernel.services
    if not svc then return {} end
    return svc.list()
end

local function readDevices()
    if not (unison and unison.rpc) then return {} end
    local d = unison.rpc.devices()
    if type(d) ~= "table" then return {} end
    local out = {}
    for id, info in pairs(d) do
        out[#out + 1] = { id = id, info = info }
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

local function readLogTail(n)
    local raw = fsLib.read(LOG_FILE)
    if not raw then return {} end
    local lines = {}
    for line in raw:gmatch("[^\n]+") do lines[#lines + 1] = line end
    local from = math.max(1, #lines - n + 1)
    local out = {}
    for i = from, #lines do out[#out + 1] = lines[i] end
    return out
end

local headerWin = {
    x = 1, y = 1, w = 0, h = 3,
    title = "UnisonOS",
    focusable = false,
    render = function(self, buf)
        local node = unison and unison.node or "?"
        local role = unison and unison.role or "?"
        local ver  = unison and unison.version or "?"
        buf:text(self.x + 2, self.y + 1,
            string.format("%s   role=%-8s  v%s", node, role, ver),
            colors.white, colors.black)
    end,
}

local svcList = widgets.list({}, {
    fg = colors.white, bg = colors.black,
    selFg = colors.black, selBg = colors.cyan,
})

local servicesWin = {
    x = 1, y = 4, w = 0, h = 0,
    title = "services",
    focusable = true,
    render = function(self, buf)
        svcList:render(buf, self.x + 1, self.y + 1, self.w - 2, self.h - 2)
    end,
    onEvent = function(self, ev) return svcList:handleEvent(ev) end,
    onTick = function(self, dt)
        local rows = readServices()
        local items = {}
        for _, r in ipairs(rows) do
            items[#items + 1] = { label = string.format("%-12s %-9s pid=%s",
                r.name:sub(1, 12), r.status, tostring(r.pid or "-")) }
        end
        svcList:setItems(items)
    end,
}

local devList = widgets.list({}, {
    fg = colors.white, bg = colors.black,
    selFg = colors.black, selBg = colors.green,
})

local devicesWin = {
    x = 0, y = 4, w = 0, h = 0,
    title = "devices",
    focusable = true,
    render = function(self, buf)
        devList:render(buf, self.x + 1, self.y + 1, self.w - 2, self.h - 2)
    end,
    onEvent = function(self, ev) return devList:handleEvent(ev) end,
    onTick = function(self, dt)
        local rows = readDevices()
        local items = {}
        for _, r in ipairs(rows) do
            items[#items + 1] = { label = string.format("%-10s %-6s %s",
                tostring(r.id):sub(1, 10), tostring(r.info.role or "-"),
                fmt.age(r.info.last_seen)) }
        end
        devList:setItems(items)
    end,
}

-- Log panel — uses unison.lib.fs.read to tail the OS log file.
local logList = widgets.list({}, {
    fg = colors.lightGray, bg = colors.black,
    selFg = colors.lightGray, selBg = colors.gray,
})

local logWin = {
    x = 1, y = 0, w = 0, h = 0,
    title = "log",
    focusable = true,
    render = function(self, buf)
        logList:render(buf, self.x + 1, self.y + 1, self.w - 2, self.h - 2)
    end,
    onEvent = function(self, ev) return logList:handleEvent(ev) end,
    onTick = function(self, dt)
        local lines = readLogTail(200)
        local items = {}
        for _, l in ipairs(lines) do items[#items + 1] = { label = l } end
        logList:setItems(items)
        if #items > 0 then logList.selected = #items end
    end,
}

local footerWin = {
    x = 1, y = 0, w = 0, h = 1,
    title = nil,
    focusable = false,
    render = function(self, buf)
        buf:text(self.x, self.y, " TAB switch  Q quit  UP/DOWN navigate ",
            colors.black, colors.lightGray)
    end,
}

local function layout()
    local w, h = term.getSize()
    headerWin.w = w
    footerWin.w = w; footerWin.y = h
    local topH = math.floor((h - 4) / 2)
    local botH = h - 4 - topH
    servicesWin.x = 1; servicesWin.y = 4
    servicesWin.w = math.floor(w / 2); servicesWin.h = topH
    devicesWin.x = servicesWin.w + 1; devicesWin.y = 4
    devicesWin.w = w - servicesWin.w; devicesWin.h = topH
    logWin.x = 1; logWin.y = 4 + topH
    logWin.w = w; logWin.h = botH
end

layout()
wm.add(headerWin)
wm.add(servicesWin)
wm.add(devicesWin)
wm.add(logWin)
wm.add(footerWin)
wm.focus(servicesWin)
wm.run()
