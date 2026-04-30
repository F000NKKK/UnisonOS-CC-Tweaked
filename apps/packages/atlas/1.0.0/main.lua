-- atlas — shared landmark registry. Every node can mark a place ("crafter",
-- "iron-deposit", "main-chest", ...) and query it later. Backs other apps
-- (autocraft asks for crafters, mine asks for known deposits, etc.).
--
-- REPL:
--   list [kind]         show landmarks
--   mark <name> <kind>  record using current GPS coords
--   put <name> <kind> <x> <y> <z>  manual coords
--   find <kind>         coords of every landmark of a kind
--   info <name>         full record
--   distance <a> <b>    block distance between two landmarks
--   remove <name>
--   q / quit
--
-- RPC: atlas_query / atlas_mark / atlas_remove (see docs/ECOSYSTEM.md).

local fsLib = unison.lib.fs

local STATE_FILE = "/unison/state/atlas.json"

local atlas = fsLib.readJson(STATE_FILE) or { landmarks = {} }
atlas.landmarks = atlas.landmarks or {}

local function save() fsLib.writeJson(STATE_FILE, atlas) end

local function myCoords()
    if not gps then return nil, "gps API not available" end
    local x, y, z = gps.locate(2)
    if not x then return nil, "gps fix failed (need GPS towers)" end
    return { x = x, y = y, z = z }
end

local function distance(a, b)
    local dx, dy, dz = (a.x or 0) - (b.x or 0), (a.y or 0) - (b.y or 0), (a.z or 0) - (b.z or 0)
    return math.sqrt(dx*dx + dy*dy + dz*dz)
end

local function add(name, kind, x, y, z, tags)
    if not (name and kind and x and y and z) then return false, "missing fields" end
    atlas.landmarks[name] = {
        name = name, kind = kind,
        x = x, y = y, z = z,
        tags = tags or {},
        owner = tostring(unison.id),
        ts = os.epoch("utc"),
    }
    save()
    return true
end

local function find(filter)
    local out = {}
    for name, lm in pairs(atlas.landmarks) do
        if (not filter.kind or lm.kind == filter.kind)
           and (not filter.name or name == filter.name) then
            out[#out + 1] = lm
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

----------------------------------------------------------------------
-- RPC
----------------------------------------------------------------------

local function setupRpc()
    if not (unison.rpc and unison.rpc.on) then return end
    unison.rpc.off("atlas_query")
    unison.rpc.off("atlas_mark")
    unison.rpc.off("atlas_remove")

    unison.rpc.on("atlas_query", function(msg, env)
        local from = env and env.msg and env.msg.from or "?"
        local items = find({ kind = msg.kind, name = msg.name })
        unison.rpc.send(from, {
            type = "atlas_reply", from = tostring(unison.id),
            in_reply_to = env and env.id, ok = true, items = items,
        })
    end)

    unison.rpc.on("atlas_mark", function(msg, env)
        local from = env and env.msg and env.msg.from or "?"
        local ok, err = add(msg.name, msg.kind, msg.x, msg.y, msg.z, msg.tags)
        unison.rpc.send(from, {
            type = "atlas_reply", from = tostring(unison.id),
            in_reply_to = env and env.id, ok = ok, err = err,
        })
    end)

    unison.rpc.on("atlas_remove", function(msg, env)
        local from = env and env.msg and env.msg.from or "?"
        atlas.landmarks[msg.name] = nil
        save()
        unison.rpc.send(from, {
            type = "atlas_reply", from = tostring(unison.id),
            in_reply_to = env and env.id, ok = true,
        })
    end)
end

----------------------------------------------------------------------
-- REPL
----------------------------------------------------------------------

local function help()
    print("atlas commands:")
    print("  list [kind]                          show landmarks")
    print("  mark <name> <kind>                   record at current GPS")
    print("  put <name> <kind> <x> <y> <z>        manual coords")
    print("  find <kind>                          coords of all matching")
    print("  info <name>                          full record")
    print("  distance <a> <b>                     block distance")
    print("  remove <name>")
    print("  q / quit")
end

local function cmdList(kind)
    local items = find({ kind = kind })
    print(string.format("%-20s %-12s %-7s %-7s %s", "NAME", "KIND", "X", "Y", "Z"))
    if #items == 0 then print("  (no landmarks)") end
    for _, lm in ipairs(items) do
        print(string.format("%-20s %-12s %-7d %-7d %d",
            lm.name:sub(1, 20), tostring(lm.kind):sub(1, 12),
            math.floor(lm.x), math.floor(lm.y), math.floor(lm.z)))
    end
end

local function cmdMark(name, kind)
    if not (name and kind) then printError("usage: mark <name> <kind>"); return end
    local pos, err = myCoords()
    if not pos then printError(err); return end
    if add(name, kind, pos.x, pos.y, pos.z) then
        print(string.format("marked %s (%s) at %d,%d,%d", name, kind,
            math.floor(pos.x), math.floor(pos.y), math.floor(pos.z)))
    end
end

local function cmdPut(name, kind, x, y, z)
    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    if not (name and kind and x and y and z) then
        printError("usage: put <name> <kind> <x> <y> <z>"); return
    end
    if add(name, kind, x, y, z) then
        print(string.format("recorded %s (%s) at %d,%d,%d", name, kind, x, y, z))
    end
end

local function cmdFind(kind)
    if not kind then printError("usage: find <kind>"); return end
    cmdList(kind)
end

local function cmdInfo(name)
    local lm = atlas.landmarks[name]
    if not lm then printError("no such landmark"); return end
    print(name)
    print("  kind:  " .. tostring(lm.kind))
    print("  pos:   " .. lm.x .. "," .. lm.y .. "," .. lm.z)
    print("  owner: " .. tostring(lm.owner))
    if lm.tags and next(lm.tags) then
        local tags = {}
        for _, t in ipairs(lm.tags) do tags[#tags + 1] = t end
        print("  tags:  " .. table.concat(tags, ", "))
    end
end

local function cmdDistance(a, b)
    local la, lb = atlas.landmarks[a], atlas.landmarks[b]
    if not (la and lb) then printError("unknown landmark(s)"); return end
    print(string.format("%s -> %s: %.1f blocks", a, b, distance(la, lb)))
end

local function cmdRemove(name)
    if not name then printError("usage: remove <name>"); return end
    atlas.landmarks[name] = nil
    save()
    print("removed " .. name)
end

setupRpc()
print("atlas online. " .. (function()
    local n = 0; for _ in pairs(atlas.landmarks) do n = n + 1 end; return n
end)() .. " landmarks loaded.")

while true do
    write("atlas> ")
    local line = read()
    if not line then break end
    line = line:gsub("^%s+", ""):gsub("%s+$", "")
    local parts = {}
    for w in line:gmatch("%S+") do parts[#parts + 1] = w end
    local cmd = parts[1]
    if not cmd or cmd == "" then
    elseif cmd == "q" or cmd == "quit" or cmd == "exit" then break
    elseif cmd == "help" or cmd == "?" then help()
    elseif cmd == "list" then cmdList(parts[2])
    elseif cmd == "mark" then cmdMark(parts[2], parts[3])
    elseif cmd == "put"  then cmdPut(parts[2], parts[3], parts[4], parts[5], parts[6])
    elseif cmd == "find" then cmdFind(parts[2])
    elseif cmd == "info" then cmdInfo(parts[2])
    elseif cmd == "distance" then cmdDistance(parts[2], parts[3])
    elseif cmd == "remove" then cmdRemove(parts[2])
    else printError("unknown: " .. cmd) end
end

if unison.rpc and unison.rpc.off then
    unison.rpc.off("atlas_query"); unison.rpc.off("atlas_mark"); unison.rpc.off("atlas_remove")
end
print("bye.")
