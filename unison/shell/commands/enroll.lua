local M = {
    desc = "Approve a pending node enrollment by code (master only)",
    usage = "enroll <code>",
}

function M.run(ctx, args)
    if unison.role ~= "master" then
        printError("enroll is only available on master node")
        return
    end
    local code = args[1]
    if not code then
        printError("usage: enroll <code>")
        return
    end
    local secret = unison.config.master and unison.config.master.secret
    if not secret or secret == "" or secret == "CHANGE_ME_BEFORE_FIRST_BOOT" then
        printError("master.secret is not set in /unison/config.lua")
        return
    end

    local enroll = dofile("/unison/net/enroll.lua")
    local netd = unison.netd
    if not netd then
        printError("netd not running")
        return
    end

    local entry, ackOrErr = enroll.masterApprove(code:upper(), secret)
    if not entry then
        printError("enroll failed: " .. tostring(ackOrErr))
        return
    end
    netd.broadcastUnsigned(ackOrErr)

    local router = dofile("/unison/net/router.lua")
    router.registerNode(entry.from, {
        role = entry.role,
        computer_id = entry.computer_id,
        enrolled_at = os.epoch("utc"),
    })

    print("approved node " .. entry.from .. " (role=" .. tostring(entry.role) .. ")")
end

return M
