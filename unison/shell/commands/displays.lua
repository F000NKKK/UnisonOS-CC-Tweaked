local M = {
    desc = "Manage attached monitors (mirroring, scale, background)",
    usage = "displays [list|enable <name>|disable <name>|scale <name> <n>|bg <name> <color>|refresh]",
}

local function svc()
    if unison and unison.display then return unison.display end
    local ok, mod = pcall(dofile, "/unison/services/display.lua")
    if not ok then return nil, mod end
    return mod
end

local function colorByName(name)
    if tonumber(name) then return tonumber(name) end
    return colors[name:lower()]
end

function M.run(ctx, args)
    local d = svc()
    if not d then printError("display service unavailable"); return end

    local sub = args[1] or "list"

    if sub == "list" then
        local rows = d.list()
        print(string.format("%-20s %-8s %-5s %s", "MONITOR", "STATE", "SCALE", "SIZE"))
        if #rows == 0 then print("  (no monitors attached)") end
        for _, r in ipairs(rows) do
            print(string.format("%-20s %-8s %-5s %dx%d",
                r.name:sub(1, 20),
                r.enabled and "enabled" or "disabled",
                tostring(r.scale),
                r.width, r.height))
        end
        return
    end

    if sub == "enable" or sub == "disable" then
        local name = args[2]
        if not name then printError("usage: displays " .. sub .. " <name>"); return end
        d.setEnabled(name, sub == "enable")
        print(sub .. "d " .. name)
        return
    end

    if sub == "scale" then
        local name, scale = args[2], tonumber(args[3])
        if not (name and scale) then printError("usage: displays scale <name> <n>"); return end
        d.setScale(name, scale)
        print("scale=" .. scale .. " for " .. name)
        return
    end

    if sub == "bg" or sub == "background" then
        local name, c = args[2], colorByName(args[3] or "")
        if not (name and c) then printError("usage: displays bg <name> <color|number>"); return end
        d.setBackground(name, c)
        print("bg set for " .. name)
        return
    end

    if sub == "refresh" then
        d.refresh()
        print("refreshed.")
        return
    end

    printError("unknown subcommand: " .. sub)
    print("usage: " .. M.usage)
end

return M
