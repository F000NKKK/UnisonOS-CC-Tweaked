return {
    name = "scanner",
    version = "1.2.0",
    description = "Turtle sphere scanner by radius with robust obstacle handling and atlas sync",
    author = "F000NKKK",
    roles = { "turtle" },
    deps = {},
    requires = { "atlas" },
    permissions = { "rpc", "turtle", "fuel", "fs", "gps", "term" },
    min_platform = "0.9.4",
    entry = "main.lua",
    files = { "main.lua" },
}
