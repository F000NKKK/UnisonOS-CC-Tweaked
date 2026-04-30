local M = {
    desc = "Adjust kernel-process priority (nice value, -20=high .. 19=low)",
    usage = "nice <pid> <delta>   (e.g. 'nice 7 -5' or 'nice 7 +3')",
}

function M.run(ctx, args)
    local pid = tonumber(args[1])
    if not pid then printError("usage: " .. M.usage); return end
    local delta = tonumber(args[2])
    if not delta then printError("usage: " .. M.usage); return end

    local sched = unison.kernel.scheduler
    local before = sched.get(pid)
    if not before then printError("no such pid: " .. pid); return end

    local ok, err = sched.nice(pid, delta)
    if not ok then printError(err or "failed"); return end

    local after = sched.get(pid)
    print(string.format("pid %d (%s): nice %d -> %d",
        pid, after.name or "?", before.priority or 0, after.priority or 0))
end

return M
