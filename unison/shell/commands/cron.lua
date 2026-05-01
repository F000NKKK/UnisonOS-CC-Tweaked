local M = {
    desc = "Manage scheduled tasks (cron.d units)",
    usage = "cron <list|run|reload|add|rm|enable|disable> ...",
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

local function fmtSchedule(r)
    if r.cron then return r.cron end
    if r.every_seconds then return "every " .. r.every_seconds .. "s" end
    return "?"
end

local function help()
    print("cron — periodic task runner")
    print("")
    print("  cron list                        list units with status")
    print("  cron run <name>                  fire a unit now")
    print("  cron reload                      re-read /unison/cron.d")
    print("  cron add <name> <expr> <command>  add unit (cron expr or 'every:Ns')")
    print("  cron rm <name>                   delete unit")
    print("  cron enable <name>               re-enable a disabled unit")
    print("  cron disable <name>              keep file, skip ticks")
    print("")
    print("Cron expression: \"<min> <hour> <dom> <month> <dow>\"")
    print("  *  N  N-M  N,M  */N    e.g.  '*/5 * * * *'  every 5 minutes")
    print("Interval syntax:  every:60   every:300   etc.")
    print("")
    print("Examples:")
    print("  cron add ping-tick \"*/5 * * * *\" \"rsend 1 ping\"")
    print("  cron add hb every:60 \"gpsnet pulse\"")
end

local function cmdList()
    local d = svc()
    if not d then printError("crond not running"); return end
    local rows = d.list()
    print(string.format("%-16s %-5s %-12s %-6s %-7s %s",
        "NAME", "ON", "WHEN", "RUNS", "LAST", "COMMAND"))
    if #rows == 0 then print("  (no cron units)") end
    for _, r in ipairs(rows) do
        print(string.format("%-16s %-5s %-12s %-6s %-7s %s",
            r.name:sub(1, 16),
            r.enabled and "yes" or "no",
            fmtSchedule(r):sub(1, 12),
            tostring(r.runs or 0),
            fmtAge(r.last_run),
            (r.command or r.description or ""):sub(1, 32)))
        if r.last_error then
            print("    [err] " .. r.last_error:sub(1, 60))
        end
    end
end

local function cmdRun(name)
    local d = svc(); if not d then printError("crond not running"); return end
    if not name then printError("usage: cron run <name>"); return end
    local ok, err = d.runOnce(name)
    if ok then print("ran " .. name) else printError(tostring(err)) end
end

local function cmdReload()
    local d = svc(); if not d then printError("crond not running"); return end
    d.discover()
    print("crond units reloaded.")
end

local function cmdAdd(args)
    local d = svc(); if not d then printError("crond not running"); return end
    local name = args[1]
    local sched = args[2]
    if not (name and sched) then printError("usage: cron add <name> <expr|every:Ns> <command...>"); return end
    -- The command is the remainder, joined.
    local cmdParts = {}
    for i = 3, #args do cmdParts[#cmdParts + 1] = args[i] end
    local command = table.concat(cmdParts, " ")
    if command == "" then printError("missing command"); return end

    local opts = { name = name, command = command }
    local everyN = sched:match("^every:(%d+)$") or sched:match("^(%d+)s?$")
    if everyN then
        opts.every_seconds = tonumber(everyN)
    else
        opts.cron = sched
    end
    local ok, err = d.add(opts)
    if ok then print("added " .. name) else printError("cron add: " .. tostring(err)) end
end

local function cmdRm(name)
    local d = svc(); if not d then printError("crond not running"); return end
    if not name then printError("usage: cron rm <name>"); return end
    local ok, err = d.remove(name)
    if ok then print("removed " .. name) else printError(tostring(err)) end
end

local function cmdSetEnabled(name, enabled)
    local d = svc(); if not d then printError("crond not running"); return end
    if not name then printError("name required"); return end
    local ok, err = d.setEnabled(name, enabled)
    if ok then print((enabled and "enabled " or "disabled ") .. name)
    else printError(tostring(err)) end
end

function M.run(ctx, args)
    local sub = args[1] or "list"
    table.remove(args, 1)
    if sub == "list" or sub == "-l" then cmdList()
    elseif sub == "run" then cmdRun(args[1])
    elseif sub == "reload" then cmdReload()
    elseif sub == "add" then cmdAdd(args)
    elseif sub == "rm" or sub == "remove" then cmdRm(args[1])
    elseif sub == "enable" then cmdSetEnabled(args[1], true)
    elseif sub == "disable" then cmdSetEnabled(args[1], false)
    elseif sub == "-h" or sub == "--help" or sub == "help" then help()
    else printError("usage: " .. M.usage); help() end
end

return M
