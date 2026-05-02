-- mine-worker service: auto-starts the mine worker daemon on any turtle
-- that has the mine package installed.
--
-- Enabled automatically when:
--   • device is a turtle (global `turtle` exists)
--   • /unison/apps/mine/main.lua exists (mine installed via upm)
--
-- The service blocks in runWorkerDaemon's event loop. The service
-- manager restarts it on failure (restart = "on-failure").

return {
    name        = "mine-worker",
    description = "mine worker daemon — waits for dispatcher assignments",
    enabled     = true,
    roles       = { "turtle" },
    deps        = { "rpcd" },
    restart     = "on-failure",
    restart_sec = 15,

    pre_start = function(cfg)
        if not turtle then return "skip" end
        if not fs.exists("/unison/apps/mine/main.lua") then return "skip" end
    end,

    main = function(cfg)
        if not turtle then return end
        if not fs.exists("/unison/apps/mine/main.lua") then return end
        -- Run mine in worker mode in the current global environment.
        -- os.run passes varargs as { ... } inside the loaded file.
        os.run(_G, "/unison/apps/mine/main.lua", "worker")
    end,
}
