local path = dofile("/unison/shell/path.lua")

local M = {
    desc = "Move / rename a file or directory",
    usage = "mv <from> <to>",
}

function M.run(ctx, args)
    if #args < 2 then printError("usage: " .. M.usage); return end
    local from = path.resolve(ctx, args[1])
    local to   = path.resolve(ctx, args[2])
    if not fs.exists(from) then printError("no such path: " .. from); return end
    if fs.isReadOnly(from) then printError("read-only source: " .. from); return end
    if fs.exists(to) and fs.isDir(to) then
        to = to .. "/" .. fs.getName(from)
    end
    if fs.exists(to) then printError("target exists: " .. to); return end
    local ok, err = pcall(fs.move, from, to)
    if ok then print(from .. " -> " .. to)
    else printError("mv: " .. tostring(err)) end
end

return M
