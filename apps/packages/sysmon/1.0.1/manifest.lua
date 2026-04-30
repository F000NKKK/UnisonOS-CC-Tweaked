return {
    name = "sysmon",
    version = "1.0.1",
    description = "TUI system monitor (services, devices, uptime)",
    author = "F000NKKK",
    roles = { "any" },
    deps = {},
    permissions = { "rpc", "term" },
    -- needs unison.ui (added in 0.5.7) and the inline-run sandbox (0.5.9)
    min_platform = "0.5.9",
    entry = "main.lua",
    files = { "main.lua" },
}
