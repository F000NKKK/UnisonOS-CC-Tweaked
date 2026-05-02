-- `home` — view, set or clear this device's home point (world coords).
--
-- The home point is the GPS-anchored location a turtle returns to when
-- it finishes a job, runs out of fuel, or is told to abort. mine reads
-- it through unison.lib.home; the dispatcher will use it to route
-- turtles back after a task. Stored at /unison/state/home.json.

local M = {
    desc = "Show / set / clear this device's home point",
    usage = "home [show | here | set <x> <y> <z> [facing] [label] | label <text> | clear]",
}

local function home() return unison and unison.lib and unison.lib.home end
local function io_()  return unison and unison.stdio end

local function show(io, h)
    if not h then
        io.print("(no home set)")
        io.print("hint: `home here` snapshots the current GPS fix")
        return
    end
    io.print(string.format("home: x=%d y=%d z=%d%s",
        h.x, h.y, h.z,
        h.facing and ("  facing=" .. h.facing) or ""))
    if h.label then io.print("label: " .. tostring(h.label)) end
    io.print(string.format("set_by=%s  set_at=%s",
        tostring(h.set_by or "?"),
        h.set_at and tostring(h.set_at) or "?"))
end

function M.run(ctx, args)
    local io = io_()  if not io then printError("stdio unavailable"); return end
    local H  = home() if not H  then io.printError("home lib unavailable"); return end

    local sub = args[1] or "show"

    if sub == "show" then
        return show(io, H.get())
    end

    if sub == "here" then
        local rec, err = H.setFromGps({ by = "shell" })
        if not rec then io.printError("home here: " .. tostring(err)); return end
        io.print("home set from GPS fix:")
        return show(io, rec)
    end

    if sub == "set" then
        local x = tonumber(args[2]); local y = tonumber(args[3]); local z = tonumber(args[4])
        if not (x and y and z) then
            io.printError("usage: home set <x> <y> <z> [facing] [label]")
            return
        end
        local facing = tonumber(args[5])
        -- Anything after facing (or after z if facing was non-numeric)
        -- is a free-form label.
        local labelStart = facing and 6 or (args[5] and 5 or nil)
        local label
        if labelStart and args[labelStart] then
            label = table.concat(args, " ", labelStart)
        end
        local rec, err = H.set({ x = x, y = y, z = z, facing = facing },
                               { by = "shell", label = label })
        if not rec then io.printError("home set: " .. tostring(err)); return end
        io.print("home set:")
        return show(io, rec)
    end

    if sub == "label" then
        local cur = H.get()
        if not cur then io.printError("no home set yet (use `home here` first)"); return end
        local label = table.concat(args, " ", 2)
        if label == "" then label = nil end
        local rec, err = H.set({ x = cur.x, y = cur.y, z = cur.z, facing = cur.facing },
                               { by = cur.set_by or "shell", label = label })
        if not rec then io.printError("home label: " .. tostring(err)); return end
        return show(io, rec)
    end

    if sub == "clear" then
        H.clear()
        io.print("home cleared.")
        return
    end

    io.printError("unknown subcommand: " .. tostring(sub))
    io.print("usage: " .. M.usage)
end

return M
