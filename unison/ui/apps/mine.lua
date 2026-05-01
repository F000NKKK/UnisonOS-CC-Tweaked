-- Mine — live status of the local mine package's job.

local Buffer = dofile("/unison/ui/buffer.lua")
local fsLib  = (unison and unison.lib and unison.lib.fs) or dofile("/unison/lib/fs.lua")

local JOB_FILE = "/unison/state/mine/job.json"

return {
    id = "mine",
    title = "Mine",
    roles = { "turtle" },
    make = function(geom)
        local job = nil
        local lastRead = 0

        local function refresh() job = fsLib.readJson(JOB_FILE) end
        refresh()

        return {
            title = "Mine",
            x = geom.x, y = geom.y, w = geom.w, h = geom.h,
            render = function(self, _)
                local b = Buffer.new(term.current())
                local x, y = self.x + 2, self.y + 1
                local fuel = turtle and turtle.getFuelLevel() or "?"
                local function line(t, fg)
                    local s = t .. string.rep(" ", math.max(0, self.w - 4 - #t))
                    b:text(x, y, s, fg or colors.white, colors.black); y = y + 1
                end
                line(string.format("Fuel: %s", tostring(fuel)),
                    (type(fuel) == "number" and fuel < 200) and colors.red or colors.lime)
                local used = 0
                if turtle then
                    for s = 1, 16 do if turtle.getItemCount(s) > 0 then used = used + 1 end end
                end
                line(string.format("Inventory: %d / 16", used))
                y = y + 1

                if not job then
                    line("Job:    (none)", colors.lightGray)
                else
                    local phase = job.phase or "?"
                    local phaseColor = colors.white
                    if phase == "mining" then phaseColor = colors.lime
                    elseif phase == "paused" then phaseColor = colors.yellow
                    elseif phase == "done"  then phaseColor = colors.lightGray
                    elseif phase == "error" then phaseColor = colors.red end
                    line("Phase:  " .. phase, phaseColor)
                    if job.shape then
                        line(string.format("Shape:  %sx%sx%s end-coords",
                            tostring(job.shape.xEnd), tostring(job.shape.yEnd), tostring(job.shape.zEnd)))
                    end
                    if job.pos then
                        line(string.format("Pos:    %s,%s,%s  facing=%s",
                            tostring(job.pos.x), tostring(job.pos.y), tostring(job.pos.z),
                            tostring(job.pos.facing)))
                    end
                    line("Dug:    " .. tostring(job.dug or 0))
                    if job.error then line("Err:    " .. job.error, colors.red) end

                    -- Progress bar.
                    if job.shape and job.shape.xEnd then
                        local total = (math.abs(job.shape.xEnd) + 1)
                                    * (math.abs(job.shape.yEnd or 0) + 1)
                                    * (math.abs(job.shape.zEnd or 0) + 1)
                        local pct = math.min(1, (job.dug or 0) / math.max(1, total))
                        local barW = self.w - 6
                        local fill = math.floor(pct * barW)
                        b:rect(x, y, fill, 1, " ", colors.lime, colors.lime)
                        b:rect(x + fill, y, barW - fill, 1, " ", colors.gray, colors.gray)
                        b:text(x, y + 1,
                            string.format("%d / %d  (%d%%)", job.dug or 0, total, math.floor(pct * 100)),
                            colors.lightGray, colors.black)
                    end
                end
            end,
            onTick = function(self)
                local now = os.epoch("utc")
                if now - lastRead > 1000 then refresh(); lastRead = now end
            end,
            onEvent = function(self, ev) end,
        }
    end,
}
