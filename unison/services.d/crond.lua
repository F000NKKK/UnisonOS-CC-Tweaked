return {
    name = "crond",
    description = "Periodic task runner (units in /unison/cron.d/)",
    enabled = true,
    roles = { "any" },
    deps = {},
    restart = "always",
    restart_sec = 5,

    main = function(cfg)
        local crond = dofile("/unison/services/crond.lua")
        unison.crond = crond
        crond.loop()
    end,
}
