local M = {
    desc = "Send a JSON-style message to a remote device via the bus",
    usage = "rsend <device_id> <type> [key=value]...",
}

local function parseKV(s)
    local k, v = s:match("^([^=]+)=(.*)$")
    if not k then return nil end
    if v == "true" then v = true
    elseif v == "false" then v = false
    elseif tonumber(v) then v = tonumber(v) end
    return k, v
end

function M.run(ctx, args)
    local target, msgType = args[1], args[2]
    if not (target and msgType) then
        printError("usage: " .. M.usage); return
    end
    local payload = { type = msgType, from = tostring(os.getComputerID()) }
    for i = 3, #args do
        local k, v = parseKV(args[i])
        if k then payload[k] = v end
    end
    local client = unison.rpc or dofile("/unison/rpc/client.lua")
    local resp, err = client.send(target, payload)
    if not resp then printError("rpc: " .. tostring(err)); return end
    print("queued message id=" .. tostring(resp.message and resp.message.id))
end

return M
