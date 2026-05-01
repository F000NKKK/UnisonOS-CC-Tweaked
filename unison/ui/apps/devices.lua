-- Devices — list of all known devices via the bus.

local Buffer = dofile("/unison/ui/buffer.lua")

return {
    id = "devices",
    title = "Devices",
    roles = { "any" },
    make = function(geom)
        local rpcClient = (unison and unison.rpc)
        local rows = {}
        local sel = 1
        local offset = 0
        local lastFetch = 0
        local fetching = false

        local function refresh()
            if not (rpcClient and rpcClient.devices) then
                rows = { { id = "-", name = "(no rpc client)" } }; return
            end
            if fetching then return end
            fetching = true
            local raw, err = rpcClient.devices()
            fetching = false
            if not raw then rows = { { id = "?", name = "err: " .. tostring(err) } }; return end
            rows = {}
            for id, d in pairs(raw) do
                if id ~= tostring(unison.id) and (d.role or "") ~= "console" then
                    rows[#rows + 1] = {
                        id = tostring(id),
                        name = d.name or "-",
                        role = d.role or "-",
                        version = d.version or "-",
                        last_seen = d.last_seen,
                        fuel = (d.metrics or {}).fuel,
                        position = (d.metrics or {}).position,
                    }
                end
            end
            table.sort(rows, function(a, b) return tostring(a.id) < tostring(b.id) end)
            if sel > #rows then sel = #rows end
            if sel < 1 then sel = 1 end
        end

        local function fmtAge(ms)
            if not ms then return "-" end
            local s = math.floor((os.epoch("utc") - ms) / 1000)
            if s < 60 then return s .. "s" end
            if s < 3600 then return math.floor(s/60) .. "m" end
            return math.floor(s/3600) .. "h"
        end

        refresh()

        return {
            title = "Devices",
            x = geom.x, y = geom.y, w = geom.w, h = geom.h,
            render = function(self, _)
                local b = Buffer.new(term.current())
                local headerY = self.y + 1
                local header = string.format(" %-4s %-10s %-8s %-6s %-5s %s",
                    "ID", "NAME", "ROLE", "VER", "SEEN", "POS")
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
                        local pos = "-"
                        if r.position then pos = string.format("%d,%d,%d", r.position.x, r.position.y, r.position.z) end
                        local line = string.format(" %-4s %-10s %-8s %-6s %-5s %s",
                            r.id:sub(1, 4),
                            (r.name or "-"):sub(1, 10),
                            (r.role or "-"):sub(1, 8),
                            (r.version or "-"):sub(1, 6),
                            fmtAge(r.last_seen):sub(1, 5),
                            pos)
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
                b:text(self.x + 1, self.y + self.h - 2, " R:refresh  P:ping ",
                    colors.lightGray, colors.black)
            end,
            onTick = function(self)
                local now = os.epoch("utc")
                if now - lastFetch > 3000 then refresh(); lastFetch = now end
            end,
            onEvent = function(self, ev)
                if ev[1] == "key" then
                    local k = ev[2]
                    if k == keys.up   and sel > 1     then sel = sel - 1; return "consumed" end
                    if k == keys.down and sel < #rows then sel = sel + 1; return "consumed" end
                    if k == keys.r    then refresh(); return "consumed" end
                    if k == keys.p    then
                        local r = rows[sel]
                        if r and r.id and rpcClient and rpcClient.send then
                            rpcClient.send(r.id, { type = "ping", ts = os.epoch("utc") })
                        end
                        return "consumed"
                    end
                end
            end,
        }
    end,
}
