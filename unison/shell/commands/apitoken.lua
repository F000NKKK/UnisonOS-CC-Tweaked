local M = {
    desc = "Manage the bearer token used to talk to the VPS API",
    usage = "apitoken <set <token>|show|clear>",
}

local TOKEN_FILE = "/unison/state/api_token"

local function ensureDir()
    if not fs.exists("/unison/state") then fs.makeDir("/unison/state") end
end

function M.run(ctx, args)
    local sub = args[1] or "show"
    if sub == "set" then
        local token = args[2]
        if not token then printError("usage: apitoken set <token>"); return end
        ensureDir()
        local h = fs.open(TOKEN_FILE, "w")
        h.write(token)
        h.close()
        print("api token saved (" .. #token .. " chars)")
        return
    end
    if sub == "show" then
        if not fs.exists(TOKEN_FILE) then print("(no token set)"); return end
        local h = fs.open(TOKEN_FILE, "r")
        local s = h.readAll(); h.close()
        if #s > 12 then s = s:sub(1, 6) .. "..." .. s:sub(-4) end
        print("token: " .. s)
        return
    end
    if sub == "clear" then
        if fs.exists(TOKEN_FILE) then fs.delete(TOKEN_FILE) end
        print("api token cleared.")
        return
    end
    printError("usage: " .. M.usage)
end

return M
