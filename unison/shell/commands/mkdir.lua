local path = dofile("/unison/shell/path.lua")

local M = {
    desc = "Create a directory (parents are created automatically)",
    usage = "mkdir <path>...",
}

function M.run(ctx, args)
    if #args == 0 then printError("usage: " .. M.usage); return end
    for _, raw in ipairs(args) do
        local target = path.resolve(ctx, raw)
        if fs.exists(target) then
            if fs.isDir(target) then
                print("(exists) " .. target)
            else
                printError("not a directory: " .. target)
            end
        else
            local ok, err = pcall(fs.makeDir, target)
            if ok then print("created " .. target)
            else printError("mkdir " .. target .. ": " .. tostring(err)) end
        end
    end
end

return M
