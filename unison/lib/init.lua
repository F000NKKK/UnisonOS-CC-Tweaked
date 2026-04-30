-- unison.lib — index of shared utilities. Loaded once and reused.

return {
    fs     = dofile("/unison/lib/fs.lua"),
    http   = dofile("/unison/lib/http.lua"),
    json   = dofile("/unison/lib/json.lua"),
    semver = dofile("/unison/lib/semver.lua"),
    path   = dofile("/unison/lib/path.lua"),
}
