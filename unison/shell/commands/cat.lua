local M = {
    desc = "Print a file to the terminal",
    usage = "cat <path>",
}

local function resolve(ctx, p)
    if p:sub(1, 1) ~= "/" then p = fs.combine(ctx.cwd, p) end
    return "/" .. fs.combine("", p)
end

function M.run(ctx, args)
    if not args[1] then printError("usage: cat <path>"); return end
    local target = resolve(ctx, args[1])
    if not fs.exists(target) then printError("no such file: " .. target); return end
    if fs.isDir(target) then printError("is a directory: " .. target); return end
    local h = fs.open(target, "r")
    if not h then printError("cannot open"); return end
    while true do
        local line = h.readLine()
        if not line then break end
        print(line)
    end
    h.close()
end

return M
