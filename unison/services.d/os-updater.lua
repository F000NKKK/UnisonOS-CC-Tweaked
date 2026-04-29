return {
    name = "os-updater",
    description = "Periodically check upstream manifest and apply OS updates",
    enabled = true,
    roles = { "any" },
    deps = {},
    restart = "always",
    restart_sec = 10,

    main = function(cfg)
        local osu = dofile("/unison/services/os_updater.lua")
        osu.loop()
    end,
}
