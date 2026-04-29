local M = {
    desc = "Revoke an enrolled node by id (master only)",
    usage = "revoke <node_id>",
}

function M.run(ctx, args)
    if unison.role ~= "master" then
        printError("revoke is only available on master node")
        return
    end
    local id = args[1]
    if not id then printError("usage: revoke <node_id>"); return end
    local router = dofile("/unison/net/router.lua")
    if router.revoke(id) then
        print("revoked " .. id)
    else
        printError("no such node: " .. id)
    end
end

return M
