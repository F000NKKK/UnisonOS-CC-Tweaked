-- Universal fuel-bus service.
--
-- Runs on every turtle. Subscribes to:
--   fuel_courier { target_pos, target_id?, amount? }
--     Dispatcher (or any peer) asks us to ferry coal to a stranded
--     turtle. We accept iff we have enough coal AND enough fuel for the
--     round-trip. Otherwise reply with fuel_courier_reply { ok=false }.
--
--   fuel_help_request (passive log)
--     Other turtles' help requests. We don't act unilaterally — the
--     dispatcher decides who's the best courier and sends fuel_courier
--     to that one — but we surface the request in the log so the player
--     can intervene.
--
-- Heartbeat reports `coal` so the dispatcher's courier-selection sees
-- which turtles are carrying fuel.

local M = {}

local function lib() return unison and unison.lib end

local function manhattan(a, b)
    if not (a and b and a.x and b.x) then return math.huge end
    return math.abs(a.x - b.x) + math.abs(a.y - b.y) + math.abs(a.z - b.z)
end

local FUEL_FLOOR = 200

local function start()
    local rpc  = unison and unison.rpc
    local fuel = lib() and lib().fuel
    if not (rpc and fuel) then return end

    -- Passive — just log.
    rpc.subscribe("fuel_help_request", function(msg, env)
        local fromId = tostring(env.from or msg.from or "?")
        if fromId == tostring(os.getComputerID()) then return end
        local f = msg.fuel or "?"
        if unison.kernel and unison.kernel.log then
            unison.kernel.log.info("fuel",
                "peer " .. fromId .. " requests fuel (fuel=" .. tostring(f) .. ")")
        end
    end)

    -- Active — execute a courier mission.
    rpc.subscribe("fuel_courier", function(msg, env)
        local target = msg.target_pos
        local amount = tonumber(msg.amount) or 32
        if not (target and target.x and target.y and target.z) then return end
        if unison.kernel and unison.kernel.log then
            unison.kernel.log.info("fuel",
                string.format("courier dispatch: deliver %d coal to (%d,%d,%d)",
                    amount, target.x, target.y, target.z))
        end

        -- Sanity-check fuel margin before committing.
        local L = lib()
        local pos
        if L and L.gps and L.gps.locate then
            local x, y, z = L.gps.locate("self", { timeout = 1 })
            if x then pos = { x = x, y = y, z = z } end
        end
        local need = manhattan(pos, target) * 2 + FUEL_FLOOR
        if (turtle and turtle.getFuelLevel() or 0) < need then
            rpc.reply(env, { type = "fuel_courier_reply",
                              ok = false, err = "insufficient fuel" })
            return
        end
        if fuel.coalCount() < amount then
            rpc.reply(env, { type = "fuel_courier_reply",
                              ok = false, err = "no coal" })
            return
        end

        -- Mark this device busy via the standard process API so OS
        -- updates defer until we land.
        local proc = unison.process
        local tok = proc and proc.markBusy and proc.markBusy("fuel-courier") or nil
        local ok, dropped = fuel.deliver(target, amount)
        if proc and proc.clearBusy then proc.clearBusy(tok) end

        rpc.reply(env, {
            type = "fuel_courier_reply",
            ok   = ok and true or false,
            err  = (not ok) and tostring(dropped) or nil,
            dropped = ok and dropped or nil,
        })
    end)
end

M.start = start
return M
