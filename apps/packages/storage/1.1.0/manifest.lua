return {
    name = "storage",
    version = "1.1.0",
    description = "Aggregate inventories on a wired-modem network as one storage pool",
    author = "F000NKKK",
    roles = { "any" },
    deps = {},
    requires = {},
    permissions = { "peripheral", "term", "fs", "rpc" },
    min_platform = "0.9.4",
    entry = "main.lua",
    files = { "main.lua" },
}
