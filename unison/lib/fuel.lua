-- unison.lib.fuel — universal fuel-help protocol for any turtle.
--
-- Any turtle can:
--   • call requestHelp()        — broadcast that it's stranded; whichever
--                                 idle peer has coal will be courier-
--                                 dispatched by the dispatcher.
--   • call clearHelp()          — let the dispatcher know it's no longer
--                                 stranded (got coal somehow).
--   • run the fuel service      — the service subscribes to fuel_courier
--                                 RPC and ferries coal to the requester.
--
-- Independent of `mine` — works for farm, patrol, scanner or a plain
-- shell. No dependency on dispatcher; the protocol gracefully degrades
-- when no dispatcher is online (broadcast is fire-and-forget; couriers
-- pick up requests on their own discovery).

local M = {}

-- Items that count as fuel for the purposes of "I have coal to lend".
M.FUEL_NAMES = {
    ["minecraft:coal"]       = true,
    ["minecraft:charcoal"]   = true,
    ["minecraft:coal_block"] = true,
}

-- Total count of fuel items in this turtle's inventory.
function M.coalCount()
    if not turtle then return 0 end
    local total = 0
    for s = 1, 16 do
        if turtle.getItemCount(s) > 0 then
            local d = turtle.getItemDetail(s)
            if d and M.FUEL_NAMES[d.name] then total = total + d.count end
        end
    end
    return total
end

-- Slot index of the first fuel item, or nil if none.
function M.firstFuelSlot()
    if not turtle then return nil end
    for s = 1, 16 do
        if turtle.getItemCount(s) > 0 then
            local d = turtle.getItemDetail(s)
            if d and M.FUEL_NAMES[d.name] then return s end
        end
    end
    return nil
end

-- Read current GPS position (best-effort, may return nil).
local function selfPosition()
    local L = unison and unison.lib
    if not (L and L.gps and L.gps.locate) then return nil end
    local x, y, z = L.gps.locate("self", { timeout = 1 })
    if not x then return nil end
    return { x = x, y = y, z = z }
end

-- Broadcast "I'm low on fuel" to the bus. Any subscriber (typically
-- the dispatcher) can pick a courier. Fire-and-forget.
function M.requestHelp(opts)
    local rpc = unison and unison.rpc
    if not rpc then return false, "no rpc" end
    opts = opts or {}
    pcall(rpc.broadcast, {
        type     = "fuel_help_request",
        from     = tostring(os.getComputerID()),
        fuel     = turtle and turtle.getFuelLevel() or nil,
        position = opts.position or selfPosition(),
        amount   = opts.amount,
        reason   = opts.reason,
    })
    return true
end

-- Tell the dispatcher we're no longer stranded (got coal, woke up
-- with fuel, etc.).
function M.clearHelp()
    local rpc = unison and unison.rpc
    if not rpc then return end
    pcall(rpc.broadcast, {
        type = "fuel_help_clear",
        from = tostring(os.getComputerID()),
    })
end

-- Ferry coal to a stranded peer. nav.goTo flies above the target,
-- dropDowns the requested coal, then returns home (if we have one).
-- Returns ok, err.
function M.deliver(targetPos, amount)
    if not turtle then return false, "not a turtle" end
    local nav = unison and unison.lib and unison.lib.nav
    if not nav then return false, "nav lib unavailable" end
    if M.coalCount() < (amount or 16) then
        return false, "not enough coal"
    end
    amount = amount or 32

    local above = { x = targetPos.x, y = targetPos.y + 1, z = targetPos.z }
    local ok, err = nav.goTo(above, { dig = false })
    if not ok then return false, "nav: " .. tostring(err) end

    local dropped = 0
    for s = 1, 16 do
        if turtle.getItemCount(s) > 0 then
            local d = turtle.getItemDetail(s)
            if d and M.FUEL_NAMES[d.name] then
                turtle.select(s)
                local cnt = math.min(turtle.getItemCount(s), amount - dropped)
                if turtle.dropDown(cnt) then dropped = dropped + cnt end
                if dropped >= amount then break end
            end
        end
    end

    -- Return home (best effort; failing to return is non-fatal).
    local h = unison and unison.lib and unison.lib.home and unison.lib.home.get()
    if h then pcall(nav.goTo, { x = h.x, y = h.y, z = h.z }, { dig = false }) end

    return true, dropped
end

return M
