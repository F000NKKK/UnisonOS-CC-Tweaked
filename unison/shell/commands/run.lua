local M = {
    desc = "Run an installed app or a Lua file path",
    usage = "run <app|path> [args...]",
}

local APPS_DIR = "/unison/apps"

local function resolve(target)
    if fs.exists(target) and not fs.isDir(target) then return target end
    local appMain = APPS_DIR .. "/" .. target .. "/main.lua"
    if fs.exists(appMain) then return appMain end
    return nil
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
    local pid = sched.spawn(function(...)
        local fn, err = loadfile(path, "t", _ENV)
        if not fn then
            printError("load error: " .. tostring(err))
            return
        end
        local ok, e = pcall(fn, ...)
        if not ok then printError("runtime error: " .. tostring(e)) end
    end, target)

    print("started " .. target .. " as pid " .. pid)
    unison.kernel.ipc.send(pid, { args = rest })
end

return M
