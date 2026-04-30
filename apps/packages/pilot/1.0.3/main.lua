-- pilot — remote turtle control over the VPS message bus.
--
-- On the turtle:    pilot listen
-- On any computer:  pilot <turtle_id>

local args = { ... }
local mode = args[1]

local function isTurtle() return unison.role == "turtle" end

----------------------------------------------------------------------
-- Turtle side (the listener) — all turtle.* references are kept inside
-- this function so the controller side never tries to read turtle globals.
----------------------------------------------------------------------

local function runListener()
    if not turtle then
        print("pilot listen: this device is not a turtle")
        return
    end

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
        place = turtle.place,
        placeup = turtle.placeUp,
        placedown = turtle.placeDown,
        suck = turtle.suck,
        drop = turtle.drop,
    }

    local function doRefuel(amount)
        local n = tonumber(amount or "")
        if n then return turtle.refuel(n) end
        return turtle.refuel()
    end

    print("pilot listening as turtle " .. tostring(unison.id))
    print("press Q to stop, or hold Ctrl+T")

    -- Replace any leftover listener from a previous run (handlers accumulate
    -- across re-installs / repeated `pilot listen`).
    if unison.rpc.off then unison.rpc.off("pilot") end

    unison.rpc.on("pilot", function(msg, env)
        local action = msg.action
        local from = env and env.msg and env.msg.from or "?"
        local resp = { type = "pilot_reply", from = tostring(unison.id), action = action }
        if action == "info" then
            resp.ok = true
            resp.fuel = turtle.getFuelLevel()
            resp.inventory = inventorySummary()
        elseif action == "sel" then
            local slot = tonumber(msg.slot or 0)
            if slot and slot >= 1 and slot <= 16 then
                turtle.select(slot)
                resp.ok = true
                resp.fuel = turtle.getFuelLevel()
            else
                resp.ok = false; resp.err = "bad slot"
            end
        elseif action == "refuel" then
            local before = turtle.getFuelLevel()
            local ok, why = doRefuel(msg.amount)
            resp.ok = ok and true or false
            resp.err = (not ok) and tostring(why or "no fuel item in selected slot") or nil
            resp.fuel = turtle.getFuelLevel()
            resp.gained = ok and (resp.fuel - before) or 0
        else
            local fn = ACTIONS[action]
            if not fn then
                resp.ok = false; resp.err = "unknown action: " .. tostring(action)
            else
                local ok, why = fn()
                resp.ok = ok and true or false
                resp.err = (not ok) and tostring(why or "blocked") or nil
                resp.fuel = turtle.getFuelLevel()
            end
        end
        unison.rpc.send(from, resp)
    end)

    while true do
        local ev, p1 = os.pullEvent()
        if ev == "char" and (p1 == "q" or p1 == "Q") then break end
        if ev == "key" and p1 == keys.q then break end
    end
    if unison.rpc.off then unison.rpc.off("pilot") end
    print("stopping pilot listener.")
end

----------------------------------------------------------------------
-- Controller side. Pure rpc client; never references turtle.*.
----------------------------------------------------------------------

local function runController(target)
    if not unison.rpc then
        print("pilot: rpc client not available; check 'service status rpcd'")
        return
    end

    -- Same hygiene on the controller side: drop any pilot_reply handler
    -- left behind by a previous controller session.
    if unison.rpc.off then unison.rpc.off("pilot_reply") end

    local replies = {}
    unison.rpc.on("pilot_reply", function(msg, env)
        replies[#replies + 1] = msg
    end)

    print("pilot -> turtle " .. target)
    print("type 'help' for commands, 'q' to quit.")

    while true do
        write("[pilot " .. target .. "]> ")
        local line = read()
        if not line then return end
        line = line:gsub("^%s+", ""):gsub("%s+$", "")

        if line == "" then
            -- nothing typed; just consume any pending replies
        elseif line == "q" or line == "quit" or line == "exit" then
            if unison.rpc.off then unison.rpc.off("pilot_reply") end
            print("bye.")
            return
        elseif line == "help" or line == "?" then
            print("  fwd back up down left right around")
            print("  dig digup digdown place placeup placedown")
            print("  sel <slot>  refuel [N]  drop  suck  info  q")
        else
            local parts = {}
            for w in line:gmatch("%S+") do parts[#parts + 1] = w end
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
end

----------------------------------------------------------------------
-- Entry
----------------------------------------------------------------------

if mode == "listen" or (not mode and isTurtle()) then
    runListener()
elseif mode then
    runController(mode)
else
    print("usage:")
    print("  on a turtle:        pilot listen")
    print("  on any computer:    pilot <turtle_id>")
end
