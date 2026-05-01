-- unison.lib — index of shared utilities. Loaded once and reused.

return {
    fs          = dofile("/unison/lib/fs.lua"),
    http        = dofile("/unison/lib/http.lua"),
    json        = dofile("/unison/lib/json.lua"),
    semver      = dofile("/unison/lib/semver.lua"),
    path        = dofile("/unison/lib/path.lua"),
    kvstore     = dofile("/unison/lib/kvstore.lua"),
    canvas      = dofile("/unison/lib/canvas.lua"),
    cli         = dofile("/unison/lib/cli.lua"),
    app         = dofile("/unison/lib/app.lua"),
    fmt         = dofile("/unison/lib/fmt.lua"),
    gps         = dofile("/unison/lib/gps.lua"),
    scrollback  = dofile("/unison/lib/scrollback.lua"),
    turtle      = dofile("/unison/lib/turtle.lua"),
    atlas       = dofile("/unison/lib/atlas.lua"),
}
