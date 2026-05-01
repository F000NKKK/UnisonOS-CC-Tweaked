return {
    name = "storage",
    version = "2.0.0",
    description = "Pool aggregator + Create-compatible; pushes snapshots to the server-side atlas",
    author = "F000NKKK",
    roles = { "any" },
    deps = {},
    requires = {},
    permissions = { "peripheral", "term", "fs", "rpc", "http" },
    min_platform = "0.17.0",
    entry = "main.lua",
    files = { "main.lua" },
}
