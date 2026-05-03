-- `displays` — list / configure monitors attached via wired modem.
--
-- Examples:
--   displays                          list every monitor with size + scale
--   displays scale <name> auto        fit shadow with no clipping (default)
--   displays scale <name> 0.5         force a specific CC scale (0.5..5)
--   displays enable  <name>           include this monitor in mirroring
--   displays disable <name>           exclude this monitor (it stays black)

local M = {
    desc  = "List / configure attached monitors (scale, primary, on/off)",
    usage = "displays [scale <name> <auto|0.5..5> | enable <name> | "
         .. "disable <name> | primary <name|none>]",
}

local function svc()
    -- The display service exposes M.list / setScale / setEnabled via
    -- the kernel global. Lazy-loaded so this command works even if
    -- the service module wasn't preloaded into unison.display.
    if unison and unison.display then return unison.display end
    local ok, mod = pcall(dofile, "/unison/services/display.lua")
    if ok and type(mod) == "table" then
        unison = unison or {}
        unison.display = mod
        return mod
    end
    return nil
end

local function out(s) if unison and unison.stdio then unison.stdio.print(s) else print(s) end end
local function err(s) if unison and unison.stdio then unison.stdio.printError(s) else printError(s) end end

local function show(d)
    local rows = d.list and d.list() or {}
    if #rows == 0 then out("(no monitors attached)") return end
    out(string.format("%-16s %-3s %-3s %-6s %s",
        "NAME", "ON", "PRI", "SCALE", "SIZE"))
    for _, r in ipairs(rows) do
        out(string.format("%-16s %-3s %-3s %-6s %dx%d",
            r.name,
            r.enabled and "y" or "-",
            r.primary and "y" or "-",
            tostring(r.scale),
            r.width, r.height))
    end
end

local function parseScale(s)
    if s == "auto" then return "auto" end
    local n = tonumber(s)
    if not n then return nil end
    -- CC accepts 0.5 .. 5 in 0.5 increments.
    if n < 0.5 or n > 5 then return nil end
    return n
end

function M.run(ctx, args)
    local d = svc()
    if not d then err("display service unavailable"); return end

    local sub = args[1]

    if not sub then return show(d) end

    if sub == "scale" then
        local name = args[2]
        local raw  = args[3]
        if not name or not raw then
            err("usage: displays scale <name> <auto|0.5..5>"); return
        end
        local s = parseScale(raw)
        if s == nil then err("scale must be 'auto' or 0.5..5 (in 0.5 steps)"); return end
        if not d.setScale then err("display.setScale unavailable"); return end
        d.setScale(name, s)
        out("scale: " .. name .. " → " .. tostring(s))
        return show(d)
    end

    if sub == "enable" or sub == "disable" then
        local name = args[2]
        if not name then err("usage: displays " .. sub .. " <name>"); return end
        if not d.setEnabled then err("display.setEnabled unavailable"); return end
        d.setEnabled(name, sub == "enable")
        out(sub .. ": " .. name)
        return show(d)
    end

    if sub == "primary" then
        local name = args[2]
        if not name then err("usage: displays primary <name|none>"); return end
        if not d.setPrimary then err("display.setPrimary unavailable"); return end
        if name == "none" or name == "off" or name == "-" then
            d.setPrimary(nil)
            out("primary: cleared (shadow back to terminal size).")
        else
            d.setPrimary(name)
            out("primary: " .. name .. " (shadow resized to its cells).")
        end
        return show(d)
    end

    err("unknown subcommand: " .. tostring(sub))
    out("usage: " .. M.usage)
end

return M
