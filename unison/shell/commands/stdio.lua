-- `stdio` — diagnose and configure the text-output pipeline.
--
-- All textual output goes through unison.stdio → term.current() (which
-- is the display multiplex once the display service is up). This
-- command is the user-facing surface for what `displays` used to do
-- (peripheral-side knobs: enabled, scale, background) plus a few
-- diagnostics: list streams, show active size + colour state.
--
-- Usage:
--   stdio                            — overview (size + monitors)
--   stdio list                       — list attached monitors
--   stdio enable  <name>             — enable mirroring to a monitor
--   stdio disable <name>             — disable mirroring
--   stdio scale   <name> <n>         — set monitor text scale
--   stdio bg      <name> <color>     — set monitor background colour
--   stdio refresh                    — re-scan peripherals
--   stdio test                       — paint a small GDI sample frame

local M = {
    desc = "Inspect and configure stdio (text output + monitor mirroring)",
    usage = "stdio [list|enable <name>|disable <name>|scale <name> <n>|bg <name> <color>|refresh|test]",
}

local function io() return unison and unison.stdio end

local function colorByName(name)
    if tonumber(name) then return tonumber(name) end
    if not name then return nil end
    return colors[name:lower()]
end

local function printRow(stdio, fmt, ...)
    stdio.print(string.format(fmt, ...))
end

local function listMonitors(stdio)
    local rows = stdio.displays.list()
    stdio.print(string.format("%-20s %-8s %-5s %s", "MONITOR", "STATE", "SCALE", "SIZE"))
    if #rows == 0 then stdio.print("  (no monitors attached)") end
    for _, r in ipairs(rows) do
        printRow(stdio, "%-20s %-8s %-5s %dx%d",
            r.name:sub(1, 20),
            r.enabled and "enabled" or "disabled",
            tostring(r.scale),
            r.width, r.height)
    end
end

local function overview(stdio)
    local w, h = stdio.size()
    local fg, bg = stdio.getColor()
    stdio.print(string.format("stdout size: %dx%d  fg=%s bg=%s  color=%s",
        w, h, tostring(fg), tostring(bg), tostring(stdio.isColor())))
    stdio.print("")
    listMonitors(stdio)
end

local function paintTest(stdio)
    local gdi = unison and unison.gdi
    if not gdi then stdio.printError("gdi unavailable"); return end
    local ctx = gdi.screen()
    ctx:fillRect(2, 2, 20, 5, colors.blue)
    ctx:frame(2, 2, 20, 5, "GDI", colors.white)
    ctx:drawText(4, 4, "stdio + gdi OK", colors.yellow, colors.blue)
    -- Restore cursor to a sane position for the prompt.
    stdio.setCursor(1, 8)
end

function M.run(ctx, args)
    local stdio = io()
    if not stdio then printError("stdio unavailable"); return end

    local sub = args[1]
    if not sub then return overview(stdio) end

    if sub == "list" then return listMonitors(stdio) end

    if sub == "enable" or sub == "disable" then
        local name = args[2]
        if not name then stdio.printError("usage: stdio " .. sub .. " <name>"); return end
        stdio.displays.setEnabled(name, sub == "enable")
        stdio.print(sub .. "d " .. name)
        return
    end

    if sub == "scale" then
        local name, scale = args[2], tonumber(args[3])
        if not (name and scale) then
            stdio.printError("usage: stdio scale <name> <n>"); return
        end
        stdio.displays.setScale(name, scale)
        stdio.print("scale=" .. scale .. " for " .. name)
        return
    end

    if sub == "bg" or sub == "background" then
        local name, c = args[2], colorByName(args[3])
        if not (name and c) then
            stdio.printError("usage: stdio bg <name> <color|number>"); return
        end
        stdio.displays.setBackground(name, c)
        stdio.print("bg set for " .. name)
        return
    end

    if sub == "refresh" then
        stdio.displays.refresh()
        stdio.print("refreshed.")
        return
    end

    if sub == "test" then
        paintTest(stdio); return
    end

    stdio.printError("unknown subcommand: " .. tostring(sub))
    stdio.print("usage: " .. M.usage)
end

return M
