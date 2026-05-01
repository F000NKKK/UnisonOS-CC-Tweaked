return {
    name = "display",
    description = "Multi-monitor display manager (mirrors term to all monitors)",
    enabled = true,
    roles = { "any" },
    deps = {},
    restart = "on-failure",
    restart_sec = 5,

    pre_start = function(cfg)
        local disp = dofile("/unison/services/display.lua")
        disp.start(cfg)
        unison.display = disp
        if unison.kernel and unison.kernel.scheduler and disp.periodicRefreshLoop then
            unison.kernel.scheduler.spawn(disp.periodicRefreshLoop, "display-refresh", { group = "system" })
        end
    end,

    main = function(cfg)
        if unison.display and unison.display.watcherLoop then
            unison.display.watcherLoop()
        end
    end,
}
