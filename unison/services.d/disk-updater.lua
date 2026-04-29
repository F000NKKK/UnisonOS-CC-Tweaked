return {
    name = "disk-updater",
    description = "Refresh attached UnisonOS-Installer floppy from upstream",
    enabled = true,
    roles = { "any" },
    deps = {},
    restart = "always",
    restart_sec = 10,

    main = function(cfg)
        local du = dofile("/unison/services/disk_updater.lua")
        du.loop()
    end,
}
