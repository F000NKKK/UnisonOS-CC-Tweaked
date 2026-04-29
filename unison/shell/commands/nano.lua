local path = dofile("/unison/shell/path.lua")

local M = {
    desc = "Edit a file with the built-in CraftOS editor",
    usage = "nano <path>",
}

local CANDIDATES = {
    "/rom/programs/edit.lua",
    "/rom/programs/edit",
}

local function findEditor()
    for _, p in ipairs(CANDIDATES) do
        if fs.exists(p) then return p end
    end
    return nil
end

function M.run(ctx, args)
    if not args[1] then printError("usage: nano <path>"); return end
    local target = path.resolve(ctx, args[1])
    local editor = findEditor()
    if not editor then printError("no editor found in /rom/programs"); return end

    -- The CraftOS shell isn't always present in our process scope, so don't
    -- rely on shell.run. Load and call the editor directly with the file path.
    local fn, err = loadfile(editor, "t", _ENV)
    if not fn then fn, err = loadfile(editor) end
    if not fn then printError("load: " .. tostring(err)); return end

    local ok, runErr = pcall(fn, target)
    if not ok then printError("editor: " .. tostring(runErr)) end
end

return M
