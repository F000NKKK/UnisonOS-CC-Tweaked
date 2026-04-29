-- sysmon — small TUI dashboard built on the unison.ui framework.

local wm      = dofile("/unison/ui/wm.lua")
local widgets = dofile("/unison/ui/widgets.lua")

local function fmtUptime(s)
    if s < 60 then return s .. "s" end
    if s < 3600 then return string.format("%dm %ds", s / 60, s % 60) end
    return string.format("%dh %dm", s / 3600, (s % 3600) / 60)
end

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

-- ---- header --------------------------------------------------------------
local headerWin = {
    x = 1, y = 1, w = 0, h = 3,
    title = "UnisonOS",
    focusable = false,
    render = function(self, buf)
        local node = unison and unison.node or "?"
        local role = unison and unison.role or "?"
        local ver  = (UNISON and UNISON.version) or "?"
        local upS  = math.floor((os.epoch("utc") - (UNISON.boot_time or 0)) / 1000)
        buf:text(self.x + 2, self.y + 1,
            string.format("%s   role=%-8s  v%s   up %s",
                node, role, ver, fmtUptime(upS)),
            colors.white, colors.black)
    end,
}

-- ---- services pane -------------------------------------------------------
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

-- ---- devices pane --------------------------------------------------------
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
            local age = "-"
            if r.info.last_seen then
                local s = math.floor((os.epoch("utc") - r.info.last_seen) / 1000)
                if s < 60 then age = s .. "s"
                elseif s < 3600 then age = math.floor(s / 60) .. "m"
                else age = math.floor(s / 3600) .. "h" end
            end
            items[#items + 1] = { label = string.format("%-10s %-6s %s",
                tostring(r.id):sub(1, 10), tostring(r.info.role or "-"), age) }
        end
        devList:setItems(items)
    end,
}

-- ---- footer --------------------------------------------------------------
local footerWin = {
    x = 1, y = 0, w = 0, h = 1,
    title = nil,
    focusable = false,
    render = function(self, buf)
        buf.t.setCursorPos(self.x, self.y)
        buf:text(self.x, self.y, " TAB switch  Q quit  UP/DOWN navigate ",
            colors.black, colors.lightGray)
    end,
}

-- ---- layout --------------------------------------------------------------
local function layout()
    local w, h = term.getSize()
    headerWin.w = w
    footerWin.w = w; footerWin.y = h
    servicesWin.x = 1; servicesWin.y = 4
    servicesWin.w = math.floor(w / 2); servicesWin.h = h - 4
    devicesWin.x = servicesWin.w + 1; devicesWin.y = 4
    devicesWin.w = w - servicesWin.w; devicesWin.h = h - 4
end

layout()
wm.add(headerWin)
wm.add(servicesWin)
wm.add(devicesWin)
wm.add(footerWin)
wm.focus(servicesWin)
wm.run()
