-- pilot — remote turtle control over the VPS message bus.
--
-- On the turtle:    pilot listen
-- On any computer:  pilot <turtle_id>
--
-- Master REPL accepts:
--   fwd / forward / go        f
--   back / b
--   up / u
--   down / d
--   left / l                  (turnLeft)
--   right / r                 (turnRight)
--   around                    (turnLeft x2)
--   dig                       (dig forward)
--   digup / du
--   digdown / dd
--   place                     (place block in front from selected slot)
--   sel <n>                   (select inventory slot)
--   info                      (ask turtle for fuel + inventory snapshot)
--   q / quit / exit
--
-- Single-letter aliases work too (f/b/u/d/l/r).

local args = { ... }
local mode = args[1]

local function isTurtle() return unison.role == "turtle" end

----------------------------------------------------------------------
-- Turtle side (the listener)
----------------------------------------------------------------------

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

local function runListener()
    if not turtle then
        print("pilot listen: this device is not a turtle")
        return
    end
    print("pilot listening as turtle " .. tostring(unison.id))
    print("waiting for commands... (Ctrl+T to stop)")

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

    while true do sleep(1) end
end

----------------------------------------------------------------------
-- Master side (the controller)
----------------------------------------------------------------------

local function runController(target)
    if not unison.rpc then
        print("pilot: rpc client not available; check 'service status rpcd'")
        return
    end

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
            print("bye.")
            return
        elseif line == "help" or line == "?" then
            print("  fwd back up down left right around")
            print("  dig digup digdown place placeup placedown")
            print("  sel <slot>  drop  suck  info  q")
        else
            local parts = {}
            for w in line:gmatch("%S+") do parts[#parts + 1] = w end
            local action = parts[1]
            local payload = { type = "pilot", action = action }
            if action == "sel" then payload.slot = tonumber(parts[2] or 0) end
            local _, err = unison.rpc.send(target, payload)
            if err then printError("send: " .. tostring(err)) end
        end

        -- Wait briefly for a reply, then drain.
        local deadline = os.epoch("utc") + 1500
        while os.epoch("utc") < deadline and #replies == 0 do sleep(0.2) end
        while #replies > 0 do
            local r = table.remove(replies, 1)
            if r.ok then
                local extra = ""
                if r.fuel  then extra = extra .. "  fuel=" .. tostring(r.fuel) end
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
