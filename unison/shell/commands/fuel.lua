-- `fuel` — show local fuel + coal, or manually broadcast fuel-help.
--
-- Usage:
--   fuel                       show this device's fuel + coal count
--   fuel help                  manually broadcast fuel_help_request
--   fuel clear                 cancel a previous fuel_help_request
--   fuel deliver <x> <y> <z>   ferry coal to a specific position
--                              (broadcasts fuel_courier; first eligible
--                              turtle responds)

local M = {
    desc  = "Inspect fuel / coal and trigger fuel-help courier protocol",
    usage = "fuel [help | clear | deliver <x> <y> <z>]",
}

local function out(s)
    if unison and unison.stdio then unison.stdio.print(s) else print(s) end
end

local function err(s)
    if unison and unison.stdio then unison.stdio.printError(s) else printError(s) end
end

function M.run(ctx, args)
    local fuelLib = unison and unison.lib and unison.lib.fuel
    if not fuelLib then err("lib.fuel unavailable"); return end

    local sub = args[1]

    if not sub then
        if turtle then
            out(string.format("fuel: %s", tostring(turtle.getFuelLevel())))
            out(string.format("coal in inventory: %d items", fuelLib.coalCount()))
        else
            out("fuel: this device is not a turtle (no fuel level)")
        end
        return
    end

    if sub == "help" then
        local ok = fuelLib.requestHelp({ reason = "shell" })
        if ok then out("fuel_help_request broadcast.")
        else err("rpc unavailable") end
        return
    end

    if sub == "clear" then
        fuelLib.clearHelp()
        out("fuel_help cleared.")
        return
    end

    if sub == "deliver" then
        local x = tonumber(args[2]); local y = tonumber(args[3]); local z = tonumber(args[4])
        if not (x and y and z) then
            err("usage: fuel deliver <x> <y> <z>")
            return
        end
        local rpc = unison and unison.rpc
        if not (rpc and rpc.broadcast) then err("rpc unavailable"); return end
        rpc.broadcast({
            type        = "fuel_courier",
            target_id   = nil,
            target_pos  = { x = x, y = y, z = z },
            amount      = tonumber(args[5]) or 32,
        })
        out(string.format("fuel_courier broadcast → (%d,%d,%d). First idle"
            .. " turtle with coal will deliver.", x, y, z))
        return
    end

    err("unknown subcommand: " .. tostring(sub))
    out("usage: " .. M.usage)
end

return M
