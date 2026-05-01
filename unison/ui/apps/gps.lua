-- GPS — live position display + diagnostic snapshot.

local Buffer = dofile("/unison/ui/buffer.lua")
local gpsLib = unison and unison.lib and unison.lib.gps
              or dofile("/unison/lib/gps.lua")
local fsLib  = unison and unison.lib and unison.lib.fs
              or dofile("/unison/lib/fs.lua")

return {
    id = "gps",
    title = "GPS",
    roles = { "any" },
    make = function(geom)
        local lastFix = nil
        local lastSrc = nil
        local lastTry = 0
        local towers = {}

        local function refresh()
            if gpsLib.resetGpsCache then gpsLib.resetGpsCache() end
            local x, y, z, src = gpsLib.locate("self", { timeout = 1 })
            if x then lastFix = { x = x, y = y, z = z }; lastSrc = src
            else lastFix = nil; lastSrc = src end
            local devs = gpsLib.devices and gpsLib.devices() or nil
            towers = {}
            if devs then
                for _, d in ipairs(devs) do
                    if d.source == "tower" or d.source == "host" then
                        towers[#towers + 1] = d
                    end
                end
            end
        end

        refresh()

        return {
            title = "GPS",
            x = geom.x, y = geom.y, w = geom.w, h = geom.h,
            render = function(self, _)
                local b = Buffer.new(term.current())
                local x, y = self.x + 2, self.y + 1
                local function line(t, fg)
                    local s = t .. string.rep(" ", math.max(0, self.w - 4 - #t))
                    b:text(x, y, s, fg or colors.white, colors.black); y = y + 1
                end
                line("Self:")
                if lastFix then
                    line(string.format("  %d, %d, %d  (%s)",
                        lastFix.x, lastFix.y, lastFix.z, tostring(lastSrc)),
                        colors.lime)
                else
                    line("  no fix  (" .. tostring(lastSrc or "?") .. ")", colors.red)
                end

                local saved = fsLib.readJson("/unison/state/gps-host.json")
                if saved and saved.x then
                    line("")
                    line(string.format("Tower self: %d,%d,%d (%s)",
                        saved.x, saved.y, saved.z, tostring(saved.source or "manual")),
                        colors.cyan)
                end

                line("")
                line("Bus towers (" .. #towers .. "):")
                local listH = self.h - y + self.y - 2
                for i = 1, math.min(listH, #towers) do
                    local t = towers[i]
                    line(string.format("  %s %s  %d,%d,%d",
                        t.id, (t.name or "-"):sub(1, 12),
                        t.x, t.y, t.z))
                end

                b:text(self.x + 1, self.y + self.h - 2, " R:refresh ",
                    colors.lightGray, colors.black)
            end,
            onTick = function()
                local now = os.epoch("utc")
                if now - lastTry > 5000 then refresh(); lastTry = now end
            end,
            onEvent = function(self, ev)
                if ev[1] == "key" and ev[2] == keys.r then
                    refresh(); return "consumed"
                end
            end,
        }
    end,
}
