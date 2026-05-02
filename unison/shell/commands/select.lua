-- `select` — manage 3D mining selections (WorldEdit-style).
--
-- Selections live in /unison/state/selections.json. The "active" one
-- (set by `select use <id>`) is the implicit target for mutating
-- subcommands so a user can chain operations without retyping ids:
--
--   select new kvas
--   select p1            # snapshot current GPS as p1
--   select p2 100 70 -50 # explicit corner
--   select expand +y 10  # extrude 10 blocks up
--   select queue         # hand off to the dispatcher

local M = {
    desc = "Mark, edit and queue 3D mining selections",
    usage = "select [list|new <name>|use <id>|show [id]|p1 [x y z]|p2 [x y z]|"
         .. "expand <axis> <n>|contract <axis> <n>|shift dx dy dz|slice <axis> <n>|"
         .. "queue|cancel|rm <id>]",
}

local function lib() return unison and unison.lib end
local function io_() return unison and unison.stdio end

local function gpsHere()
    local L = lib(); if not (L and L.gps) then return nil, "gps lib unavailable" end
    local x, y, z, src = L.gps.locate("self", { timeout = 2 })
    if not x then return nil, "no gps fix" end
    if src ~= "gps" and src ~= "host" and src ~= "tower" then
        return nil, "gps source: " .. tostring(src)
    end
    return { x = math.floor(x + 0.5), y = math.floor(y + 0.5), z = math.floor(z + 0.5) }
end

local function getSel(io, sels, id)
    local sel = id and sels.load(id) or sels.active()
    if not sel then
        io.printError(id and ("selection not found: " .. id) or "no active selection (use `select use <id>` or `select new <name>`)")
        return nil
    end
    return sel
end

local function fmtPoint(p)
    if not p then return "—" end
    return string.format("(%d,%d,%d)", p.x, p.y, p.z)
end

local function showOne(io, sel)
    local s = sel:summary()
    io.print(string.format("[%s] %s   state=%s", s.id, s.name, s.state))
    io.print("  p1: " .. fmtPoint(sel.p1) .. "   p2: " .. fmtPoint(sel.p2))
    if s.volume then
        io.print(string.format("  volume: %s..%s   dim=%dx%dx%d   blocks=%d",
            fmtPoint(s.volume.min), fmtPoint(s.volume.max),
            s.dimensions[1], s.dimensions[2], s.dimensions[3], s.blocks))
    else
        io.print("  volume: (incomplete — set p1 and p2)")
    end
    if #sel.history > 0 then
        io.print("  history:")
        local last = math.min(8, #sel.history)
        for i = #sel.history - last + 1, #sel.history do
            local h = sel.history[i]
            local desc = h.kind
            if h.axis  then desc = desc .. " " .. h.axis end
            if h.delta then desc = desc .. " " .. h.delta end
            if h.n     then desc = desc .. " n=" .. h.n end
            if h.p     then desc = desc .. " " .. fmtPoint(h.p) end
            if h.to    then desc = desc .. " → " .. h.to end
            io.print("    " .. desc)
        end
    end
end

local function handlePoint(io, sels, sel, which, args, i)
    local p
    if args[i] and args[i + 1] and args[i + 2] then
        p = { x = tonumber(args[i]), y = tonumber(args[i + 1]), z = tonumber(args[i + 2]) }
        if not (p.x and p.y and p.z) then
            io.printError("bad coords"); return
        end
    else
        local err
        p, err = gpsHere(); if not p then io.printError(err); return end
    end
    if which == "p1" then sel:setP1(p) else sel:setP2(p) end
    sel:save()
    showOne(io, sel)
end

function M.run(ctx, args)
    local io = io_(); if not io then printError("stdio unavailable"); return end
    local L = lib(); if not (L and L.selection) then io.printError("selection lib unavailable"); return end
    local sels = L.selection

    local sub = args[1] or "list"

    if sub == "list" then
        local rows = sels.list()
        if #rows == 0 then io.print("(no selections)"); return end
        local activeId = sels.activeId()
        io.print(string.format("%-20s %-12s %-10s %s", "ID", "NAME", "STATE", "BLOCKS"))
        for _, sel in ipairs(rows) do
            local s = sel:summary()
            local mark = (sel.id == activeId) and "*" or " "
            io.print(string.format("%s%-19s %-12s %-10s %s",
                mark, sel.id:sub(1, 19), (s.name or ""):sub(1, 12),
                s.state, tostring(s.blocks)))
        end
        return
    end

    if sub == "new" then
        local name = args[2] or "untitled"
        local sel = sels.new({ name = name, owner = "shell" })
        sel:save(); sels.setActive(sel.id)
        io.print("created: " .. sel.id)
        showOne(io, sel)
        return
    end

    if sub == "use" then
        local id = args[2]; if not id then io.printError("usage: select use <id>"); return end
        local sel = sels.load(id); if not sel then io.printError("not found: " .. id); return end
        sels.setActive(id); io.print("active: " .. id)
        return
    end

    if sub == "show" then
        local sel = getSel(io, sels, args[2]); if not sel then return end
        showOne(io, sel); return
    end

    if sub == "p1" or sub == "p2" then
        local sel = getSel(io, sels); if not sel then return end
        handlePoint(io, sels, sel, sub, args, 2)
        return
    end

    if sub == "expand" or sub == "contract" then
        local axis = args[2]; local delta = tonumber(args[3])
        if not (axis and delta) then
            io.printError("usage: select " .. sub .. " <axis> <n>"); return
        end
        local sel = getSel(io, sels); if not sel then return end
        local ok, err = (sub == "expand") and sel:expand(axis, delta) or sel:contract(axis, delta)
        if ok == false then io.printError(err); return end
        sel:save(); showOne(io, sel)
        return
    end

    if sub == "shift" then
        local dx, dy, dz = tonumber(args[2]), tonumber(args[3]), tonumber(args[4])
        if not (dx and dy and dz) then
            io.printError("usage: select shift dx dy dz"); return
        end
        local sel = getSel(io, sels); if not sel then return end
        sel:shift(dx, dy, dz); sel:save(); showOne(io, sel)
        return
    end

    if sub == "slice" then
        local axis = args[2]; local n = tonumber(args[3])
        if not (axis and n) then io.printError("usage: select slice <axis> <n>"); return end
        local sel = getSel(io, sels); if not sel then return end
        local ok, err = sel:slice(axis, n); if ok == false then io.printError(err); return end
        sel:save(); showOne(io, sel)
        return
    end

    if sub == "queue" then
        local sel = getSel(io, sels); if not sel then return end
        if not sel.volume then io.printError("no volume yet"); return end
        sel:queue(); sel:save()
        io.print("queued: " .. sel.id)
        showOne(io, sel)
        return
    end

    if sub == "cancel" then
        local sel = getSel(io, sels, args[2]); if not sel then return end
        sel:cancel(); sel:save()
        io.print("cancelled: " .. sel.id)
        return
    end

    if sub == "rm" then
        local id = args[2]; if not id then io.printError("usage: select rm <id>"); return end
        local sel = sels.load(id); if not sel then io.printError("not found: " .. id); return end
        sel:remove()
        if sels.activeId() == id then sels.setActive(nil) end
        io.print("removed: " .. id)
        return
    end

    io.printError("unknown subcommand: " .. tostring(sub))
    io.print("usage: " .. M.usage)
end

return M
