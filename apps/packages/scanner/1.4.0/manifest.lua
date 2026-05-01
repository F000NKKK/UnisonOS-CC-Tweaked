return {
    name = "scanner",
    version = "1.4.0",
    description = "Sphere scanner: streams every block to the server-side atlas (no local map)",
    author = "F000NKKK",
    roles = { "turtle" },
    deps = {},
    requires = {},
    permissions = { "rpc", "turtle", "fuel", "fs", "gps", "term", "http" },
    min_platform = "0.16.0",
    entry = "main.lua",
    files = { "main.lua" },
}
