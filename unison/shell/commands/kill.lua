local M = {
    desc = "Terminate a process by PID",
    usage = "kill <pid>",
}

function M.run(ctx, args)
    local pid = tonumber(args[1])
    if not pid then
        printError("usage: kill <pid>")
        return
    end
    local sched = unison.kernel.scheduler
    if not sched.exists(pid) then
        printError("no such pid: " .. pid)
        return
    end
    if sched.kill(pid) then
        print("killed pid " .. pid)
    else
        printError("failed to kill pid " .. pid)
    end
end

return M
