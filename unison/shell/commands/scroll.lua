local M = {
    desc = "Open the scrollback pager (PgUp/PgDn, mouse wheel, q to close)",
    usage = "scroll",
}

function M.run(ctx, args)
    local sb = (ctx and ctx.scrollback) or unison.lib.scrollback
    sb.pager()
end

return M
