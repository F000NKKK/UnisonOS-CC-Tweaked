local M = {
    desc = "Run a shell command on a remote device via the bus",
    usage = "rexec <device_id> <command...>",
}

function M.run(ctx, args)
    local target = args[1]
    if not target or #args < 2 then printError("usage: " .. M.usage); return end
    local cmd = table.concat(args, " ", 2)
    local client = unison.rpc or dofile("/unison/rpc/client.lua")
    local resp, err = client.send(target, {
        type = "exec",
        command = cmd,
        from = tostring(os.getComputerID()),
    })
    if not resp then printError("rpc: " .. tostring(err)); return end
    print("queued exec on " .. target .. ": " .. cmd)
end

return M
