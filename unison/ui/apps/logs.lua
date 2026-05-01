-- Logs — live tail of /unison/logs/current.log.

local Buffer = dofile("/unison/ui/buffer.lua")

local LOG_FILE = "/unison/logs/current.log"

return {
    id = "logs",
    title = "Logs",
    roles = { "any" },
    make = function(geom)
        local lines = {}
        local offset = 0           -- scroll position from end (0 = bottom)
        local lastSize = -1

        local function readTail()
            if not fs.exists(LOG_FILE) then lines = { "(no log file yet)" }; return end
            local size = fs.getSize(LOG_FILE)
            if size == lastSize then return end
            lastSize = size
            local h = fs.open(LOG_FILE, "r")
            if not h then return end
            local data = h.readAll() or ""
            h.close()
            lines = {}
            for line in (data .. "\n"):gmatch("([^\n]*)\n") do
                lines[#lines + 1] = line
            end
        end

        readTail()

        return {
            title = "Logs",
            x = geom.x, y = geom.y, w = geom.w, h = geom.h,
            render = function(self, _)
                local b = Buffer.new(term.current())
                local listH = self.h - 3
                local total = #lines
                local startIdx = math.max(1, total - listH + 1 - offset)
                for i = 1, listH do
                    local idx = startIdx + i - 1
                    local row = lines[idx] or ""
                    if #row > self.w - 2 then row = row:sub(1, self.w - 2) end
                    row = row .. string.rep(" ", self.w - 2 - #row)
                    local fg = colors.white
                    if row:find("ERROR") or row:find("FAIL") then fg = colors.red
                    elseif row:find("WARN") then fg = colors.yellow
                    elseif row:find("INFO") then fg = colors.lightGray
                    elseif row:find("DEBUG") then fg = colors.gray end
                    b:text(self.x + 1, self.y + i, row, fg, colors.black)
                end
                b:text(self.x + 1, self.y + self.h - 2,
                    string.format(" %d lines | PgUp/PgDn scroll | Home: bottom ", #lines),
                    colors.lightGray, colors.black)
            end,
            onTick = function() readTail() end,
            onEvent = function(self, ev)
                if ev[1] == "key" then
                    local k = ev[2]
                    local listH = self.h - 3
                    if k == keys.up       then offset = offset + 1; return "consumed" end
                    if k == keys.down     then offset = math.max(0, offset - 1); return "consumed" end
                    if k == keys.pageUp   then offset = math.min(#lines, offset + listH); return "consumed" end
                    if k == keys.pageDown then offset = math.max(0, offset - listH); return "consumed" end
                    if k == keys.home or k == keys["end"] then offset = 0; return "consumed" end
                end
            end,
        }
    end,
}
