return {
    name = "sysmon",
    version = "1.0.2",
    description = "TUI system monitor (services, devices, log tail)",
    author = "F000NKKK",
    roles = { "any" },
    deps = {},
    permissions = { "rpc", "term" },
    -- Uses unison.ui (added in 0.5.7) and unison.lib.fs (added in 0.8.0).
    min_platform = "0.8.0",
    entry = "main.lua",
    files = { "main.lua" },
}
