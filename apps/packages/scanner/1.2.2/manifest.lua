return {
    name = "scanner",
    version = "1.2.2",
    description = "Turtle sphere scanner by radius with obstacle handling and atlas sync",
    author = "F000NKKK",
    roles = { "turtle" },
    deps = {},
    requires = { "atlas" },
    permissions = { "rpc", "turtle", "fuel", "fs", "gps", "term" },
    min_platform = "0.9.6",
    entry = "main.lua",
    files = { "main.lua" },
}
