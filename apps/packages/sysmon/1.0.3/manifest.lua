return {
    name = "sysmon",
    version = "1.0.3",
    description = "TUI system monitor (services, devices, log tail)",
    author = "F000NKKK",
    roles = { "any" },
    deps = {},
    requires = {},
    permissions = { "rpc", "term" },
    min_platform = "0.9.4",
    entry = "main.lua",
    files = { "main.lua" },
}
