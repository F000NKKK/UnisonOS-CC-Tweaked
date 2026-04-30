local M = {
    desc = "List running processes (PID, nice, group, state, CPU, uptime)",
    usage = "ps",
}

function M.run(ctx, args)
    local sched = unison.kernel.scheduler
    local procs = sched.list()
    print(string.format("%-4s %-3s %-9s %-8s %-7s %-7s %s",
        "PID", "NI", "GROUP", "STATE", "CPU", "UP", "NAME"))
    local now = os.epoch("utc")
    for _, p in ipairs(procs) do
        local uptime = math.floor((now - (p.started or now)) / 1000)
        local cpu = string.format("%5.2fs", p.cpu_time or 0)
        print(string.format("%-4d %-3d %-9s %-8s %-7s %-7s %s",
            p.pid, p.priority or 0,
            (p.group or "user"):sub(1, 9),
            (p.status or "?"):sub(1, 8),
            cpu, uptime .. "s",
            (p.name or "?"):sub(1, 30)))
    end
end

return M
