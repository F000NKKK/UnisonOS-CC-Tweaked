-- atlas 1.1.0 — UniAPI-native rewrite. Uses lib.cli for the REPL,
-- lib.kvstore for state, lib.app for RPC subscription, rpc.reply
-- for outbound replies.

local lib   = unison.lib
local cli   = lib.cli
local app   = lib.app
local store = lib.kvstore.open("atlas", { landmarks = {} })

local landmarks = store:get("landmarks", {})

local function persist() store:set("landmarks", landmarks) end

local function myCoords()
    if not gps then return nil, "gps API not available" end
    local x, y, z = gps.locate(2)
    if not x then return nil, "gps fix failed (need GPS towers)" end
    return { x = x, y = y, z = z }
end

local function add(name, kind, x, y, z, tags)
    landmarks[name] = {
        name = name, kind = kind, x = x, y = y, z = z,
        tags = tags or {},
        owner = tostring(unison.id),
        ts = os.epoch("utc"),
    }
    persist()
end

local function find(filter)
    local out = {}
    for name, lm in pairs(landmarks) do
        if (not filter.kind or lm.kind == filter.kind)
           and (not filter.name or name == filter.name) then
            out[#out + 1] = lm
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

----------------------------------------------------------------------
-- RPC handlers — registered through app.subscribeAll
----------------------------------------------------------------------

local function onQuery(msg, env)
    unison.rpc.reply(env, {
        type = "atlas_reply",
        ok = true,
        items = find({ kind = msg.kind, name = msg.name }),
    })
end
local function onMark(msg, env)
    if not (msg.name and msg.kind and msg.x and msg.y and msg.z) then
        return unison.rpc.reply(env, { type = "atlas_reply", ok = false, err = "missing fields" })
    end
    add(msg.name, msg.kind, msg.x, msg.y, msg.z, msg.tags)
    unison.rpc.reply(env, { type = "atlas_reply", ok = true })
end
local function onRemove(msg, env)
    landmarks[msg.name] = nil; persist()
    unison.rpc.reply(env, { type = "atlas_reply", ok = true })
end

local unsubscribe = app.subscribeAll({
    atlas_query  = onQuery,
    atlas_mark   = onMark,
    atlas_remove = onRemove,
})

----------------------------------------------------------------------
-- CLI
----------------------------------------------------------------------

local function printRows(items)
    print(string.format("%-20s %-12s %-7s %-7s %s", "NAME", "KIND", "X", "Y", "Z"))
    if #items == 0 then print("  (none)") end
    for _, lm in ipairs(items) do
        print(string.format("%-20s %-12s %-7d %-7d %d",
            lm.name:sub(1, 20), tostring(lm.kind):sub(1, 12),
            math.floor(lm.x), math.floor(lm.y), math.floor(lm.z)))
    end
end

cli.run({
    intro = "atlas online. " .. (function()
        local n = 0; for _ in pairs(landmarks) do n = n + 1 end; return n
    end)() .. " landmarks loaded.",
    prompt = "atlas",
    commands = {
        list = {
            desc = "show landmarks (optional kind filter)",
            args = { { name = "kind", default = nil } },
            run  = function(_, a) printRows(find({ kind = a.kind })) end,
        },
        mark = {
            desc = "record a landmark at the current GPS position",
            args = {
                { name = "name", required = true },
                { name = "kind", required = true },
            },
            run = function(_, a)
                local pos, err = myCoords()
                if not pos then printError(err); return end
                add(a.name, a.kind, pos.x, pos.y, pos.z)
                print(string.format("marked %s (%s) at %d,%d,%d",
                    a.name, a.kind, math.floor(pos.x), math.floor(pos.y), math.floor(pos.z)))
            end,
        },
        put = {
            desc = "manually record landmark coords",
            args = {
                { name = "name", required = true },
                { name = "kind", required = true },
                { name = "x",    type = "number", required = true },
                { name = "y",    type = "number", required = true },
                { name = "z",    type = "number", required = true },
            },
            run = function(_, a)
                add(a.name, a.kind, a.x, a.y, a.z)
                print(string.format("recorded %s (%s) at %d,%d,%d", a.name, a.kind, a.x, a.y, a.z))
            end,
        },
        find = {
            desc = "show landmarks of a given kind",
            args = { { name = "kind", required = true } },
            run = function(_, a) printRows(find({ kind = a.kind })) end,
        },
        info = {
            desc = "full record for a landmark",
            args = { { name = "name", required = true } },
            run  = function(_, a)
                local lm = landmarks[a.name]
                if not lm then printError("no such landmark"); return end
                print(a.name)
                print("  kind:  " .. tostring(lm.kind))
                print("  pos:   " .. lm.x .. "," .. lm.y .. "," .. lm.z)
                print("  owner: " .. tostring(lm.owner))
            end,
        },
        distance = {
            desc = "block distance between two landmarks",
            args = {
                { name = "a", required = true },
                { name = "b", required = true },
            },
            run = function(_, a)
                local la, lb = landmarks[a.a], landmarks[a.b]
                if not (la and lb) then printError("unknown landmark(s)"); return end
                local dx, dy, dz = la.x - lb.x, la.y - lb.y, la.z - lb.z
                print(string.format("%s -> %s: %.1f blocks", a.a, a.b,
                    math.sqrt(dx*dx + dy*dy + dz*dz)))
            end,
        },
        remove = {
            desc = "delete a landmark",
            args = { { name = "name", required = true } },
            run = function(_, a)
                landmarks[a.name] = nil; persist()
                print("removed " .. a.name)
            end,
        },
    },
    on_exit = function() unsubscribe() end,
})
