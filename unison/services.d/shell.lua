return {
    name = "shell",
    description = "Interactive UnisonOS shell on the local terminal",
    enabled = true,
    roles = { "any" },
    deps = { "display" },
    restart = "always",
    restart_sec = 1,

    main = function(cfg)
        local shell_main = dofile("/unison/shell/shell.lua")
        shell_main()
    end,
}
