-- Universal fuel-bus service.
-- Runs on every turtle (any role). Subscribes to fuel_courier and
-- fuel_help_request RPCs. See unison/lib/fuel.lua for the protocol.

return {
    name        = "fuel",
    description = "Universal fuel-help courier (any turtle can deliver coal)",
    enabled     = true,
    roles       = { "turtle" },
    deps        = { "rpcd" },
    restart     = "on-failure",
    restart_sec = 10,

    pre_start = function(cfg)
        if not turtle then return "skip" end
    end,

    main = function(cfg)
        if not turtle then return end
        local svc = dofile("/unison/services/fuel.lua")
        svc.start()
        -- Long-lived subscriber; sleep forever (rpc events drive work).
        while true do sleep(60) end
    end,
}
