-- top — htop-style live process list. Q to quit, sorts by cpu_time desc.

local M = {
    desc = "Live kernel process monitor (Q to quit)",
    usage = "top",
}

local function fmtAge(epoch)
    if not epoch then return "-" end
    local s = math.floor((os.epoch("utc") - epoch) / 1000)
    if s < 60 then return s .. "s" end
    if s < 3600 then return math.floor(s / 60) .. "m" end
    return math.floor(s / 3600) .. "h"
end

local function render()
    local rows = unison.kernel.scheduler.list()
    table.sort(rows, function(a, b)
        return (a.cpu_time or 0) > (b.cpu_time or 0)
    end)

    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)

    local w, h = term.getSize()
    if term.isColor and term.isColor() then term.setTextColor(colors.cyan) end
    print(string.format("UnisonOS top   %d process(es)   %s", #rows,
        os.date and os.date("%H:%M:%S") or ""))
    if term.setTextColor then term.setTextColor(colors.lightGray) end
    print(string.format("%-4s %-3s %-10s %-8s %-7s %-7s %s",
        "PID", "NI", "GROUP", "STATE", "CPU", "RSM", "NAME"))
    term.setTextColor(colors.white)

    for i, r in ipairs(rows) do
        if i + 2 >= h then break end
        local cpu = string.format("%5.2fs", r.cpu_time or 0)
        print(string.format("%-4d %-3d %-10s %-8s %-7s %-7d %s",
            r.pid, r.priority or 0,
            (r.group or "user"):sub(1, 10),
            (r.status or "?"):sub(1, 8),
            cpu, r.resumes or 0,
            (r.name or "?"):sub(1, w - 45)))
    end

    if term.isColor and term.isColor() then term.setTextColor(colors.gray) end
    term.setCursorPos(1, h)
    write(" Q quit  R refresh  ")
    term.setTextColor(colors.white)
end

function M.run(ctx, args)
    local refreshSec = tonumber(args[1]) or 1
    local timer = os.startTimer(refreshSec)
    render()
    while true do
        local ev, p = os.pullEvent()
        if ev == "timer" and p == timer then
            render()
            timer = os.startTimer(refreshSec)
        elseif ev == "key" then
            if p == keys.q then break end
            if p == keys.r then render() end
        elseif ev == "char" and (p == "q" or p == "Q") then
            break
        end
    end
    term.setBackgroundColor(colors.black)
    term.clear()
    term.setCursorPos(1, 1)
end

return M
