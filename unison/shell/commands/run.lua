local M = {
    desc = "Run an installed app or a Lua file path",
    usage = "run <app|path> [args...]",
}

local APPS_DIR = "/unison/apps"

local function resolveApp(name)
    local dir = APPS_DIR .. "/" .. name
    if fs.exists(dir .. "/manifest.lua") then
        local fn = loadfile(dir .. "/manifest.lua")
        if fn then
            local ok, m = pcall(fn)
            if ok and type(m) == "table" and m.entry then
                return dir .. "/" .. m.entry
            end
        end
    end
    if fs.exists(dir .. "/main.lua") then return dir .. "/main.lua" end
    return nil
end

local function resolve(target)
    if fs.exists(target) and not fs.isDir(target) then return target end
    return resolveApp(target)
end

function M.run(ctx, args)
    if #args == 0 then
        printError("usage: run <app|path> [args...]")
        return
    end
    local target = args[1]
    local rest = {}
    for i = 2, #args do rest[#rest + 1] = args[i] end

    local path = resolve(target)
    if not path then
        printError("not found: " .. target)
        return
    end

    local sched = unison.kernel.scheduler
    local pid = sched.spawn(function()
        local fn, err = loadfile(path, "t", _ENV)
        if not fn then
            printError("load error: " .. tostring(err))
            return
        end
        local ok, e = pcall(fn, table.unpack(rest))
        if not ok then printError("runtime error: " .. tostring(e)) end
    end, target)

    print("started " .. target .. " as pid " .. pid)
end

return M
