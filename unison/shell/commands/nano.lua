local M = {
    desc = "Edit a file with the built-in text editor",
    usage = "nano <path>",
}

local function resolve(ctx, p)
    if p:sub(1, 1) ~= "/" then p = fs.combine(ctx.cwd, p) end
    return "/" .. fs.combine("", p)
end

function M.run(ctx, args)
    if not args[1] then printError("usage: nano <path>"); return end
    local target = resolve(ctx, args[1])
    -- Delegate to CC:Tweaked's built-in editor; it ships with CraftOS.
    if fs.exists("/rom/programs/edit.lua") then
        shell.run("/rom/programs/edit.lua", target)
        return
    end
    if fs.exists("/rom/programs/edit") then
        shell.run("/rom/programs/edit", target)
        return
    end
    printError("no editor available (looked in /rom/programs/edit)")
end

return M
