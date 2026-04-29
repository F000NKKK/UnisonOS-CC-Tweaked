local M = {
    desc = "Print last N lines of a file (use -f to follow)",
    usage = "tail [-n N] [-f] <path>",
}

local function resolve(ctx, p)
    if p:sub(1, 1) ~= "/" then p = fs.combine(ctx.cwd, p) end
    return "/" .. fs.combine("", p)
end

local function tailLines(path, n)
    local h = fs.open(path, "r")
    if not h then return {} end
    local lines = {}
    while true do
        local line = h.readLine()
        if not line then break end
        lines[#lines + 1] = line
    end
    h.close()
    local from = math.max(1, #lines - n + 1)
    local out = {}
    for i = from, #lines do out[#out + 1] = lines[i] end
    return out, #lines
end

function M.run(ctx, args)
    local n = 20
    local follow = false
    local path
    local i = 1
    while i <= #args do
        local a = args[i]
        if a == "-f" then follow = true
        elseif a == "-n" then n = tonumber(args[i + 1]) or 20; i = i + 1
        else path = a end
        i = i + 1
    end
    if not path then printError("usage: " .. M.usage); return end
    local target = resolve(ctx, path)
    if not fs.exists(target) then printError("no such file: " .. target); return end

    local lines, total = tailLines(target, n)
    for _, l in ipairs(lines) do print(l) end

    if not follow then return end

    print("--- following (Ctrl-T to abort) ---")
    while true do
        sleep(1)
        local h = fs.open(target, "r")
        if h then
            local count = 0
            while true do
                local line = h.readLine()
                if not line then break end
                count = count + 1
                if count > total then print(line) end
            end
            h.close()
            total = count
        end
    end
end

return M
