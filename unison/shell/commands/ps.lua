local M = {
    desc = "List running processes",
    usage = "ps",
}

function M.run(ctx, args)
    local sched = unison.kernel.scheduler
    local procs = sched.list()
    print(string.format("%-5s %-12s %-8s %s", "PID", "NAME", "STATUS", "UPTIME"))
    local now = os.epoch("utc")
    for _, p in ipairs(procs) do
        local uptime = math.floor((now - p.started) / 1000)
        print(string.format("%-5d %-12s %-8s %ds", p.pid, p.name:sub(1, 12), p.status, uptime))
    end
end

return M
