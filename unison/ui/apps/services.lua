-- Services — list of registered units with status.

local Buffer = dofile("/unison/ui/buffer.lua")

return {
    id = "services",
    title = "Services",
    roles = { "any" },
    make = function(geom)
        local svc = unison and unison.kernel and unison.kernel.services
        local rows = {}
        local sel = 1
        local offset = 0

        local function refresh()
            local list = (svc and svc.list and svc.list()) or {}
            rows = list
            table.sort(rows, function(a, b)
                return tostring(a.name) < tostring(b.name)
            end)
            if sel > #rows then sel = #rows end
            if sel < 1 then sel = 1 end
        end

        refresh()

        return {
            title = "Services",
            x = geom.x, y = geom.y, w = geom.w, h = geom.h,
            render = function(self, _)
                local b = Buffer.new(term.current())
                local headerY = self.y + 1
                local header = string.format(" %-16s %-9s %-3s %s",
                    "NAME", "STATE", "RST", "DESC")
                if #header > self.w - 2 then header = header:sub(1, self.w - 2) end
                header = header .. string.rep(" ", self.w - 2 - #header)
                b:text(self.x + 1, headerY, header, colors.yellow, colors.black)

                local listH = self.h - 4
                if sel < offset + 1 then offset = sel - 1 end
                if sel > offset + listH then offset = sel - listH end
                for i = 1, listH do
                    local idx = i + offset
                    local r = rows[idx]
                    if r then
                        local line = string.format(" %-16s %-9s %-3s %s",
                            tostring(r.name or "?"):sub(1, 16),
                            tostring(r.status or r.state or "-"):sub(1, 9),
                            tostring(r.restarts or 0),
                            tostring(r.description or ""):sub(1, 28))
                        if #line > self.w - 2 then line = line:sub(1, self.w - 2) end
                        line = line .. string.rep(" ", self.w - 2 - #line)
                        local fg = colors.white
                        if r.status == "running" or r.state == "running" then fg = colors.lime end
                        if r.status == "failed" or r.state == "failed" then fg = colors.red end
                        if idx == sel then
                            b:text(self.x + 1, headerY + i, line, colors.black, colors.yellow)
                        else
                            b:text(self.x + 1, headerY + i, line, fg, colors.black)
                        end
                    else
                        b:text(self.x + 1, headerY + i, string.rep(" ", self.w - 2),
                            colors.white, colors.black)
                    end
                end
                b:text(self.x + 1, self.y + self.h - 2, " R:restart  Enter:logs ",
                    colors.lightGray, colors.black)
            end,
            onTick = function() refresh() end,
            onEvent = function(self, ev)
                if ev[1] == "key" then
                    local k = ev[2]
                    if k == keys.up   and sel > 1     then sel = sel - 1; return "consumed" end
                    if k == keys.down and sel < #rows then sel = sel + 1; return "consumed" end
                    if k == keys.r and svc and svc.restart then
                        local r = rows[sel]
                        if r and r.name then svc.restart(r.name) end
                        refresh(); return "consumed"
                    end
                end
            end,
        }
    end,
}
