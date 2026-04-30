local path = dofile("/unison/shell/path.lua")

local M = {
    desc = "Delete files / directories. -r recursive, -f silent on missing",
    usage = "rm [-r] [-f] <path>...",
}

local PROTECTED = {
    ["/"] = true, ["/rom"] = true,
    ["/unison"] = true, ["/unison/state"] = true,
    ["/unison/config.lua"] = true,
}

function M.run(ctx, args)
    local recursive, force = false, false
    local targets = {}
    for _, a in ipairs(args) do
        if a == "-r" or a == "-R" or a == "--recursive" then recursive = true
        elseif a == "-f" or a == "--force" then force = true
        elseif a == "-rf" or a == "-fr" then recursive = true; force = true
        else targets[#targets + 1] = a end
    end
    if #targets == 0 then printError("usage: " .. M.usage); return end

    for _, raw in ipairs(targets) do
        local target = path.resolve(ctx, raw)
        if PROTECTED[target] then
            printError("refusing to delete " .. target)
        elseif not fs.exists(target) then
            if not force then printError("no such path: " .. target) end
        elseif fs.isReadOnly(target) then
            printError("read-only: " .. target)
        elseif fs.isDir(target) and not recursive then
            printError("is a directory (use -r): " .. target)
        else
            local ok, err = pcall(fs.delete, target)
            if ok then print("removed " .. target)
            else printError("rm " .. target .. ": " .. tostring(err)) end
        end
    end
end

return M
