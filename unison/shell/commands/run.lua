local M = {
    desc = "Run an installed app or a Lua file path (sandboxed by manifest)",
    usage = "run <app|path> [args...]",
}

local APPS_DIR = "/unison/apps"

local function loadManifest(dir)
    local p = dir .. "/manifest.lua"
    if not fs.exists(p) then return nil end
    local fn, err = loadfile(p)
    if not fn then return nil, err end
    local ok, m = pcall(fn)
    if not ok or type(m) ~= "table" then return nil, "manifest invalid" end
    return m
end

-- Resolve a target string into { path, manifest|nil, name|nil }.
local function resolve(target)
    if fs.exists(target) and not fs.isDir(target) then
        return { path = target }
    end
    local dir = APPS_DIR .. "/" .. target
    local m = loadManifest(dir)
    if m and m.entry then
        return { path = dir .. "/" .. m.entry, manifest = m, name = target }
    end
    if fs.exists(dir .. "/main.lua") then
        return { path = dir .. "/main.lua", name = target }
    end
    return nil
end

function M.run(ctx, args)
    if #args == 0 then
        printError("usage: run <app|path> [args...]"); return
    end
    local target = args[1]
    local rest = {}
    for i = 2, #args do rest[#rest + 1] = args[i] end

    local res = resolve(target)
    if not res then printError("not found: " .. target); return end

    local sandbox = dofile("/unison/kernel/sandbox.lua")

    local permissions
    if res.manifest then
        permissions = res.manifest.permissions
        if not permissions or #permissions == 0 then
            permissions = {}
        end
    else
        permissions = { "all" }
    end

    -- Inline execution: the app runs in the shell's coroutine, so its
    -- pullEvent calls are the only ones receiving input while it's active.
    -- This avoids the "shell and app both consume keys" duplication that
    -- happens with sched.spawn. The shell prompt resumes when the app exits.
    local ok, err = sandbox.execFile(res.path, permissions, table.unpack(rest))
    if not ok then printError("runtime error: " .. tostring(err)) end
end

return M
