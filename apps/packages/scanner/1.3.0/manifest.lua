return {
    name = "scanner",
    version = "1.3.0",
    description = "Sphere scanner with batched persistence (avoids O(N²) save) and ore-only filter by default",
    author = "F000NKKK",
    roles = { "turtle" },
    deps = {},
    requires = { "atlas" },
    permissions = { "rpc", "turtle", "fuel", "fs", "gps", "term" },
    min_platform = "0.9.6",
    entry = "main.lua",
    files = { "main.lua" },
}
