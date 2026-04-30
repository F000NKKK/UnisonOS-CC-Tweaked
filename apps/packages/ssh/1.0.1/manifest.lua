return {
    name = "ssh",
    version = "1.0.1",
    description = "Share / control a device's terminal over the bus (server + client)",
    author = "F000NKKK",
    roles = { "any" },
    deps = {},
    requires = {},
    permissions = { "rpc", "term" },
    min_platform = "0.10.3",
    entry = "main.lua",
    files = { "main.lua" },
}
