local path = dofile("/unison/shell/path.lua")

local M = {
    desc = "Create empty file(s) (no-op if they already exist)",
    usage = "touch <path>...",
}

function M.run(ctx, args)
    if #args == 0 then printError("usage: " .. M.usage); return end
    for _, raw in ipairs(args) do
        local target = path.resolve(ctx, raw)
        if fs.exists(target) then
            print("(exists) " .. target)
        else
            local dir = fs.getDir(target)
            if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
            local h = fs.open(target, "w")
            if not h then printError("touch " .. target .. ": cannot create")
            else h.close(); print("created " .. target) end
        end
    end
end

return M
