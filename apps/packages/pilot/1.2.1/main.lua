-- pilot 1.1.0 — UniAPI rewrite. Listener uses lib.app.runService;
-- controller uses lib.kvstore for per-target history and a lightweight
-- read-loop (cli.run isn't a fit because every line is a free-form
-- pilot move, not a fixed command list).

local lib = unison.lib
local app = lib.app

local args = { ... }
local mode = args[1]

local function isTurtle() return unison.role == "turtle" end

----------------------------------------------------------------------
-- Listener (turtle side)
----------------------------------------------------------------------

local function runListener()
    if not turtle then print("pilot listen: not a turtle"); return end

    local function inventorySummary()
        local items = {}
        for i = 1, 16 do
            local n = turtle.getItemCount(i)
            if n > 0 then
                local d = turtle.getItemDetail(i)
                items[#items + 1] = string.format("[%d]%s x%d",
                    i, d and d.name:gsub("minecraft:", "") or "?", n)
            end
        end
        return table.concat(items, " ")
    end

    local ACTIONS = {
        fwd = turtle.forward, forward = turtle.forward, go = turtle.forward, f = turtle.forward,
        back = turtle.back, b = turtle.back,
        up = turtle.up, u = turtle.up,
        down = turtle.down, d = turtle.down,
        left = turtle.turnLeft, l = turtle.turnLeft,
        right = turtle.turnRight, r = turtle.turnRight,
        around = function() turtle.turnLeft(); return turtle.turnLeft() end,
        dig = turtle.dig,
        digup = turtle.digUp, du = turtle.digUp,
        digdown = turtle.digDown, dd = turtle.digDown,
        place = turtle.place, placeup = turtle.placeUp, placedown = turtle.placeDown,
        suck = turtle.suck, drop = turtle.drop,
    }

    local function doRefuel(amount)
        local n = tonumber(amount or "")
        if n then return turtle.refuel(n) end
        return turtle.refuel()
    end

    app.runService({
        intro = "pilot listening as turtle " .. tostring(unison.id) .. "  (Q to stop)",
        outro = "stopping pilot listener.",
        busy_on_handler = true,
        handlers = {
            pilot = function(msg, env)
                local action = msg.action
                local resp = { type = "pilot_reply", action = action }
                if action == "info" then
                    resp.ok = true; resp.fuel = turtle.getFuelLevel()
                    resp.inventory = inventorySummary()
                elseif action == "sel" then
                    local slot = tonumber(msg.slot or 0)
                    if slot and slot >= 1 and slot <= 16 then
                        turtle.select(slot); resp.ok = true; resp.fuel = turtle.getFuelLevel()
                    else resp.ok = false; resp.err = "bad slot" end
                elseif action == "refuel" then
                    local before = turtle.getFuelLevel()
                    local ok, why = doRefuel(msg.amount)
                    resp.ok = ok and true or false
                    resp.err = (not ok) and tostring(why or "no fuel item") or nil
                    resp.fuel = turtle.getFuelLevel()
                    resp.gained = ok and (resp.fuel - before) or 0
                else
                    local fn = ACTIONS[action]
                    if not fn then resp.ok = false; resp.err = "unknown action: " .. tostring(action)
                    else
                        local ok, why = fn()
                        resp.ok = ok and true or false
                        resp.err = (not ok) and tostring(why or "blocked") or nil
                        resp.fuel = turtle.getFuelLevel()
                    end
                end
                unison.rpc.reply(env, resp)
            end,
        },
    })
end

----------------------------------------------------------------------
-- Controller side
----------------------------------------------------------------------

local function runController(target)
    if not unison.rpc then print("pilot: rpc client not available"); return end

    local store = lib.kvstore.open("pilot-history-" .. tostring(target))
    local history = store:get("lines", {})

    local replies = {}
    local unsubscribe = app.subscribeAll({
        pilot_reply = function(msg) replies[#replies + 1] = msg end,
    })

    print("pilot -> turtle " .. target)
    if #history > 0 then print("(" .. #history .. " lines of history; ↑/↓ to recall)") end
    print("type 'help' for commands, 'q' to quit.")

    local function persist()
        local capped = history
        if #capped > 200 then
            capped = {}; for i = #history - 199, #history do capped[#capped + 1] = history[i] end
        end
        store:set("lines", capped)
    end

    while true do
        write("[pilot " .. target .. "]> ")
        local line = read(nil, history)
        if not line then break end
        line = line:gsub("^%s+", ""):gsub("%s+$", "")
        if line == "" then
        elseif line == "q" or line == "quit" or line == "exit" then
            persist(); print("bye."); break
        elseif line == "help" or line == "?" then
            print("  fwd back up down left right around")
            print("  dig digup digdown place placeup placedown")
            print("  sel <slot>  refuel [N]  drop  suck  info  q")
            history[#history + 1] = line
        else
            history[#history + 1] = line
            local parts = {}; for w in line:gmatch("%S+") do parts[#parts + 1] = w end
            local action = parts[1]
            local payload = { type = "pilot", action = action }
            if action == "sel" then payload.slot = tonumber(parts[2] or 0) end
            if action == "refuel" and parts[2] then payload.amount = tonumber(parts[2]) end
            local _, err = unison.rpc.send(target, payload)
            if err then printError("send: " .. tostring(err)) end
        end

        local deadline = os.epoch("utc") + 1500
        while os.epoch("utc") < deadline and #replies == 0 do sleep(0.2) end
        while #replies > 0 do
            local r = table.remove(replies, 1)
            if r.ok then
                local extra = ""
                if r.fuel then extra = extra .. "  fuel=" .. tostring(r.fuel) end
                if r.gained and r.gained > 0 then extra = extra .. " (+" .. tostring(r.gained) .. ")" end
                if r.inventory then extra = extra .. "  inv=" .. tostring(r.inventory) end
                print("ok " .. tostring(r.action) .. extra)
            else
                printError("fail " .. tostring(r.action) .. ": " .. tostring(r.err))
            end
        end
    end

    unsubscribe()
end

if mode == "listen" or (not mode and isTurtle()) then runListener()
elseif mode then runController(mode)
else
    print("usage:")
    print("  on a turtle:        pilot listen")
    print("  on any computer:    pilot <turtle_id>")
end
