local M = {
    desc = "Reboot the device (defers if a user job is busy unless -f)",
    usage = "reboot [-f|--force]",
}

local function isBusy()
    local proc = unison and unison.process
    if not proc or not proc.busyJobs then return nil end
    local jobs = proc.busyJobs()
    if jobs[1] then return jobs[1].name end
    return nil
end

function M.run(ctx, args)
    local force = false
    for _, a in ipairs(args or {}) do
        if a == "-f" or a == "--force" then force = true end
    end
    if not force then
        local why = isBusy()
        if why then
            printError("reboot deferred — busy: " .. why
                .. "  (use 'reboot -f' to override)")
            return
        end
    end
    print("rebooting...")
    sleep(0.3)
    os.reboot()
end

return M
