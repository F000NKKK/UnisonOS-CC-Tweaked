-- Procs — process viewer (top).

local Buffer = dofile("/unison/ui/buffer.lua")

return {
    id = "procs",
    title = "Procs",
    roles = { "any" },
    make = function(geom)
        local sched = unison and unison.kernel and unison.kernel.scheduler
        local rows = {}
        local sel = 1
        local offset = 0

        local function refresh()
            rows = (sched and sched.list and sched.list()) or {}
            table.sort(rows, function(a, b)
                if (a.group or "") ~= (b.group or "") then
                    return (a.group or "") < (b.group or "")
                end
                return tostring(a.name) < tostring(b.name)
            end)
            if sel > #rows then sel = #rows end
            if sel < 1 then sel = 1 end
        end

        refresh()

        return {
            title = "Procs (" .. #rows .. ")",
            x = geom.x, y = geom.y, w = geom.w, h = geom.h,
            render = function(self, _)
                self.title = "Procs (" .. #rows .. ")"
                local b = Buffer.new(term.current())
                local headerY = self.y + 1
                local header = string.format(" %-4s %-7s %-3s  %s ",
                    "PID", "GROUP", "PRI", "NAME")
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
                        local line = string.format(" %-4s %-7s %-3s  %s",
                            tostring(r.pid or "?"),
                            (r.group or "-"):sub(1, 7),
                            tostring(r.priority or "0"),
                            tostring(r.name or "?"))
                        if #line > self.w - 2 then line = line:sub(1, self.w - 2) end
                        line = line .. string.rep(" ", self.w - 2 - #line)
                        if idx == sel then
                            b:text(self.x + 1, headerY + i, line, colors.black, colors.yellow)
                        else
                            b:text(self.x + 1, headerY + i, line, colors.white, colors.black)
                        end
                    else
                        b:text(self.x + 1, headerY + i, string.rep(" ", self.w - 2),
                            colors.white, colors.black)
                    end
                end
                b:text(self.x + 1, self.y + self.h - 2, " R:refresh  Del:kill ",
                    colors.lightGray, colors.black)
            end,
            onTick = function() refresh() end,
            onEvent = function(self, ev)
                if ev[1] == "key" then
                    local k = ev[2]
                    if k == keys.up   and sel > 1     then sel = sel - 1; return "consumed" end
                    if k == keys.down and sel < #rows then sel = sel + 1; return "consumed" end
                    if k == keys.r    then refresh(); return "consumed" end
                    if k == keys.delete then
                        local r = rows[sel]
                        if r and r.pid and sched and sched.kill then sched.kill(r.pid) end
                        refresh(); return "consumed"
                    end
                end
            end,
        }
    end,
}
