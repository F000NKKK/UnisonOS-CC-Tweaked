local M = {
    desc = "Change current working directory",
    usage = "cd [path]",
}

local function resolve(ctx, p)
    if not p or p == "" or p == "~" then return "/" end
    if p:sub(1, 1) ~= "/" then
        p = fs.combine(ctx.cwd, p)
    end
    if p == "" then p = "/" end
    return "/" .. fs.combine("", p)
end

function M.run(ctx, args)
    local target = resolve(ctx, args[1])
    if not fs.exists(target) then
        printError("no such directory: " .. target); return
    end
    if not fs.isDir(target) then
        printError("not a directory: " .. target); return
    end
    ctx.cwd = target
end

return M
