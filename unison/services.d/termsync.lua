return {
    name = "termsync",
    description = "Stream terminal frames + accept keyboard input from bus subscribers",
    enabled = true,
    roles = { "any" },
    deps = { "rpcd" },
    restart = "on-failure",
    restart_sec = 5,

    main = function(cfg)
        local svc = dofile("/unison/services/termsync.lua")
        unison.termsync = svc
        svc.run()
    end,
}
