local M = {
    desc = "Manage scheduled tasks (cron.d units)",
    usage = "cron <list|run <name>|reload>",
}

local function svc()
    return unison and unison.crond
end

local function fmtAge(epochSec)
    if not epochSec then return "-" end
    local s = math.floor(os.epoch("utc") / 1000 - epochSec)
    if s < 60 then return s .. "s" end
    if s < 3600 then return math.floor(s / 60) .. "m" end
    return math.floor(s / 3600) .. "h"
end

local function cmdList()
    local d = svc()
    if not d then printError("crond not running"); return end
    local rows = d.list()
    print(string.format("%-16s %-7s %-7s %-7s %s", "NAME", "ENABLED", "EVERY", "LAST", "DESC"))
    if #rows == 0 then print("  (no cron units)") end
    for _, r in ipairs(rows) do
        print(string.format("%-16s %-7s %-7s %-7s %s",
            r.name:sub(1, 16),
            r.enabled and "yes" or "no",
            tostring(r.every_seconds or "-") .. "s",
            fmtAge(r.last_run),
            (r.description or ""):sub(1, 30)))
    end
end

local function cmdRun(name)
    local d = svc()
    if not d then printError("crond not running"); return end
    if not name then printError("usage: cron run <name>"); return end
    local ok, err = d.runOnce(name)
    if ok then print("ran " .. name) else printError(tostring(err)) end
end

local function cmdReload()
    local d = svc()
    if not d then printError("crond not running"); return end
    d.discover()
    print("crond units reloaded.")
end

function M.run(ctx, args)
    local sub = args[1] or "list"
    if sub == "list" then cmdList()
    elseif sub == "run" then cmdRun(args[2])
    elseif sub == "reload" then cmdReload()
    else printError("usage: " .. M.usage) end
end

return M
