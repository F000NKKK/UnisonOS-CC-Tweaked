-- `face` — view or set this turtle's cached world facing.
--
-- nav.lib needs to know which world axis "+forward" points to.
-- Normally probed via vanilla GPS, but if vanilla GPS panics (loop
-- in gettable from /rom/apis/gps.lua) we can't probe. Use this
-- command to record the facing manually:
--
--   face                 show current facing (0=+x 1=+z 2=-x 3=-z)
--   face 0|1|2|3         set facing
--   face +x|+z|-x|-z     set facing by axis
--   face clear           wipe state file (force re-probe)

local M = {
    desc  = "Show / set this turtle's world facing for nav.lib",
    usage = "face [<0..3 | +x|+z|-x|-z | clear>]",
}

local nav = unison and unison.lib and unison.lib.nav

local AXES = {
    ["+x"] = 0, ["+z"] = 1, ["-x"] = 2, ["-z"] = 3,
    ["0"] = 0, ["1"] = 1, ["2"] = 2, ["3"] = 3,
}

local NAMES = { [0] = "+x (east)", [1] = "+z (south)",
                [2] = "-x (west)", [3] = "-z (north)" }

local function out(s) if unison and unison.stdio then unison.stdio.print(s) else print(s) end end
local function err(s) if unison and unison.stdio then unison.stdio.printError(s) else printError(s) end end

function M.run(ctx, args)
    if not nav then err("lib.nav unavailable"); return end
    local sub = args[1]

    if not sub then
        local f = nav.facing and nav.facing({ dig = false })
        if f == nil then
            err("nav.facing returned nil — no GPS, no cache, no override")
            return
        end
        out("facing: " .. tostring(f) .. "  " .. (NAMES[f] or "?"))
        return
    end

    if sub == "clear" then
        if nav.invalidateFacing then nav.invalidateFacing() end
        out("facing cache cleared. next nav call will re-probe.")
        return
    end

    local v = AXES[sub]
    if v == nil then err("invalid: " .. sub .. " (use 0..3 or +x/+z/-x/-z)"); return end
    if not nav.setFacing then err("nav.setFacing unavailable"); return end
    local ok, e = nav.setFacing(v)
    if not ok then err("setFacing: " .. tostring(e)); return end
    out("facing set to " .. v .. "  " .. (NAMES[v] or "?"))
end

return M
