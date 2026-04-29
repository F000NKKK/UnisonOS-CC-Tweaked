local M = {
    desc = "Show UnisonOS version and node info",
    usage = "version",
}

function M.run(ctx, args)
    local v = (UNISON and UNISON.version) or "?"
    print("UnisonOS " .. v)
    print("  node: " .. tostring(unison.node))
    print("  role: " .. tostring(unison.role))
    print("  id:   " .. tostring(unison.id))
end

return M
