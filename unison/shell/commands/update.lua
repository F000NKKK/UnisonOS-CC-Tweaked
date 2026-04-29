local M = {
    desc = "Check for an OS update right now and apply if available",
    usage = "update",
}

function M.run(ctx, args)
    local osu = dofile("/unison/services/os_updater.lua")
    print("checking upstream manifest...")
    local applied = osu.checkOnce()
    if not applied then
        print("no update applied (already current or fetch failed).")
    end
end

return M
