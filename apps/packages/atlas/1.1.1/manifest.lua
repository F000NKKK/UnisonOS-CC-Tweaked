return {
    name = "atlas",
    version = "1.1.1",
    description = "Shared landmark / location registry (uses unison.lib.gps)",
    author = "F000NKKK",
    roles = { "any" },
    deps = {},
    requires = {},
    permissions = { "rpc", "fs", "gps", "term" },
    min_platform = "0.9.6",
    entry = "main.lua",
    files = { "main.lua" },
}
