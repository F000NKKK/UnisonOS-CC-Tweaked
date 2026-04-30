return {
    name = "gps-host",
    description = "Auto-host this device's coordinates as a CC GPS tower",
    enabled = true,
    -- Runs on every device; skips itself at runtime if it's a turtle/pocket.
    roles = { "any" },
    deps = {},
    restart = "on-failure",
    restart_sec = 30,

    main = function(cfg)
        local svc = dofile("/unison/services/gps_host.lua")
        unison.gps_host = svc
        svc.run()
    end,
}
