local M = {
    desc = "Check for an OS update right now and apply if available",
    usage = "update",
}

function M.run(ctx, args)
    local osu = dofile("/unison/services/os_updater.lua")
    print("checking upstream manifest...")
    local applied, why = osu.checkOnce(true)
    if not applied then
        print("no update applied: " .. tostring(why))
    end
end

return M
