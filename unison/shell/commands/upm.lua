local M = {
    desc = "Unison Packet Manager — install/remove/list packages",
    usage = "upm <search|info|install|list|remove|update> [args]",
}

local function pm()
    return dofile("/unison/pm/installer.lua")
end

local function registry()
    return dofile("/unison/pm/registry.lua")
end

local function help()
    print("UPM — Unison Packet Manager")
    print("")
    print("subcommands:")
    print("  search <q>            search the registry")
    print("  info <name>           show package details")
    print("  install <name>[@<v>]  install or replace a package")
    print("  list                  list installed packages")
    print("  remove <name>         uninstall a package")
    print("  update [<name>]       update an app package (one or all)")
    print("  upgrade [-y]          check for and apply an OS upgrade")
    print("  sources               show configured sources")
end

local function cmdUpgrade(args)
    local yes = false
    for _, a in ipairs(args) do
        if a == "-y" or a == "--yes" then yes = true end
    end
    local osu = dofile("/unison/services/os_updater.lua")
    print("checking upstream manifest...")
    -- Fetch manifest first so we can show the user what we'd do.
    local manifest, err = osu.peekManifest and osu.peekManifest()
    if not manifest then
        if err then printError("upm: " .. tostring(err)); return end
        -- old api fallback: just call checkOnce verbose
        osu.checkOnce(true)
        return
    end
    local installed = osu.currentVersion and osu.currentVersion()
    print("  installed: " .. tostring(installed))
    print("  available: " .. tostring(manifest.version))
    if installed == manifest.version then
        print("already on the latest version.")
        return
    end
    if not yes then
        write("apply upgrade? (yes/no) > ")
        local ans = read()
        if ans ~= "yes" and ans ~= "y" and ans ~= "YES" and ans ~= "Y" then
            print("aborted.")
            return
        end
    end
    osu.applyManifest(manifest)
end

local function cmdSearch(args)
    local q = args[1] or ""
    local results, err = pm().search(q)
    if not results then printError("upm: " .. tostring(err)); return end
    print(string.format("%-20s %-8s %s", "NAME", "VER", "DESCRIPTION"))
    local empty = true
    for name, info in pairs(results) do
        empty = false
        print(string.format("%-20s %-8s %s",
            name:sub(1, 20), tostring(info.latest), tostring(info.description or "-")))
    end
    if empty then print("  (no packages match)") end
end

local function cmdInfo(args)
    local name = args[1]
    if not name then printError("usage: upm info <name>"); return end
    local d, err = pm().info(name)
    if not d then printError("upm: " .. tostring(err)); return end
    local r, m = d.registry, d.manifest
    print(name)
    print("  version:     " .. m.version)
    print("  description: " .. tostring(m.description or "-"))
    print("  author:      " .. tostring(m.author or "-"))
    print("  roles:       " .. table.concat(m.roles or { "any" }, ", "))
    print("  permissions: " .. table.concat(m.permissions or {}, ", "))
    print("  files:       " .. table.concat(m.files or {}, ", "))
    print("  versions:    " .. table.concat(r.versions or { m.version }, ", "))
    print("  source:      " .. d.source)
end

local function cmdInstall(args)
    local arg1 = args[1]
    if not arg1 then printError("usage: upm install <name>[@<version>]"); return end
    local name, version = arg1:match("^([^@]+)@(.+)$")
    if not name then name = arg1 end
    print("installing " .. name .. (version and ("@" .. version) or "") .. "...")
    local ok, info = pm().install(name, version)
    if not ok then printError("upm: " .. tostring(info)); return end
    print("installed " .. info.name .. "@" .. info.version)
    print("run with: run " .. info.name)
end

local function cmdList()
    local all = registry().all()
    print(string.format("%-20s %-8s %s", "NAME", "VERSION", "INSTALLED"))
    local names = {}
    for n in pairs(all) do names[#names + 1] = n end
    table.sort(names)
    if #names == 0 then print("  (no packages installed)") end
    for _, n in ipairs(names) do
        local e = all[n]
        local age = "-"
        if e.installed_at then
            local s = math.floor((os.epoch("utc") - e.installed_at) / 1000)
            if s < 60 then age = s .. "s ago"
            elseif s < 3600 then age = math.floor(s / 60) .. "m ago"
            else age = math.floor(s / 3600) .. "h ago" end
        end
        print(string.format("%-20s %-8s %s", n:sub(1, 20), tostring(e.version), age))
    end
end

local function cmdRemove(args)
    local name = args[1]
    if not name then printError("usage: upm remove <name>"); return end
    local ok, err = pm().remove(name)
    if not ok then printError("upm: " .. tostring(err)); return end
    print("removed " .. name)
end

local function cmdUpdate(args)
    if #args == 0 then
        local res = pm().updateAll()
        local any = false
        for n, r in pairs(res) do
            any = true
            if r.ok then print("updated " .. n)
            else print("skipped " .. n .. ": " .. tostring(r.info)) end
        end
        if not any then print("no installed packages.") end
        return
    end
    local name = args[1]
    local ok, info = pm().update(name)
    if not ok then printError("upm: " .. tostring(info)); return end
    print("updated " .. info.name .. "@" .. info.version)
end

local function cmdSources()
    local s = dofile("/unison/pm/sources.lua")
    for i, src in ipairs(s.list()) do
        print(string.format("  %d. %s", i, src))
    end
end

function M.run(ctx, args)
    local sub = args[1] or "help"
    local rest = {}
    for i = 2, #args do rest[#rest + 1] = args[i] end

    if     sub == "search"  then cmdSearch(rest)
    elseif sub == "info"    then cmdInfo(rest)
    elseif sub == "install" then cmdInstall(rest)
    elseif sub == "list" or sub == "ls" then cmdList()
    elseif sub == "remove" or sub == "rm" then cmdRemove(rest)
    elseif sub == "update"  then cmdUpdate(rest)
    elseif sub == "upgrade" then cmdUpgrade(rest)
    elseif sub == "sources" then cmdSources()
    elseif sub == "help"    then help()
    else printError("unknown subcommand: " .. sub); help() end
end

return M
