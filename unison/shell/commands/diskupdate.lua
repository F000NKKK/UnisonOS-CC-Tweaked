local M = {
    desc = "Manually refresh attached UnisonOS-Installer disk now",
    usage = "diskupdate",
}

function M.run(ctx, args)
    local du = dofile("/unison/services/disk_updater.lua")
    local n = du.runOnce()
    if n == 0 then
        print("no changes (or no labelled disk found).")
    else
        print("refreshed " .. n .. " file(s).")
    end
end

return M
