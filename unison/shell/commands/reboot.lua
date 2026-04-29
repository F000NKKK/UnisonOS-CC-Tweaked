local M = {
    desc = "Reboot the device",
    usage = "reboot",
}

function M.run(ctx, args)
    print("rebooting...")
    sleep(0.3)
    os.reboot()
end

return M
