local path = dofile("/unison/shell/path.lua")

local M = {
    desc = "Change current working directory",
    usage = "cd [path]",
}

function M.run(ctx, args)
    local target = path.resolve(ctx, args[1])
    if not fs.exists(target) then
        printError("no such directory: " .. target); return
    end
    if not fs.isDir(target) then
        printError("not a directory: " .. target); return
    end
    ctx.cwd = target
end

return M
