-- `world` — get or set this device's bus world_id.
--
-- The world_id partitions the message bus so devices in different
-- Minecraft worlds connecting to the same server don't see each
-- other (no shared /api/devices, /api/messages, /api/broadcast).
-- See README "Cross-world isolation" for the full picture.
--
-- Stored in /unison/state/world.json (overrides config.lua world_id).
-- Restart rpcd (or reboot) for the change to take effect.
--
-- Usage:
--   world                  show current world_id and source
--   world <name>           set to <name> (e.g. "alpha", "creative")
--   world clear            remove override (falls back to config or "default")

local M = {
    desc  = "Get or set the bus world_id (cross-world bus isolation)",
    usage = "world [<name> | clear]",
}

local STATE = "/unison/state/world.json"

local function readState()
    local L = unison and unison.lib
    if L and L.fs and L.fs.readJson then return L.fs.readJson(STATE) or {} end
    if not fs.exists(STATE) then return {} end
    local h = fs.open(STATE, "r"); if not h then return {} end
    local s = h.readAll(); h.close()
    local ok, t = pcall(textutils.unserializeJSON, s)
    return ok and type(t) == "table" and t or {}
end

local function writeState(t)
    local L = unison and unison.lib
    if L and L.fs and L.fs.writeJson then return L.fs.writeJson(STATE, t) end
    if not fs.exists("/unison/state") then fs.makeDir("/unison/state") end
    local h = fs.open(STATE, "w"); if not h then return false end
    h.write(textutils.serializeJSON(t)); h.close(); return true
end

local function currentWorld()
    local s = readState()
    if s.world_id then return s.world_id, "state" end
    if unison and unison.config and unison.config.world_id then
        return tostring(unison.config.world_id), "config"
    end
    return "default", "default"
end

local function out(s)
    if unison and unison.stdio then unison.stdio.print(s) else print(s) end
end

local function err(s)
    if unison and unison.stdio then unison.stdio.printError(s) else printError(s) end
end

-- Allow only filesystem-/URL-safe characters so the value lines up with
-- what the server's _world_id() helper sanitises to.
local function isValid(name)
    if type(name) ~= "string" or name == "" or #name > 64 then return false end
    return name:match("^[%w_%-%.]+$") ~= nil
end

function M.run(ctx, args)
    local sub = args[1]

    if not sub then
        local w, src = currentWorld()
        out("world: " .. w .. "  (" .. src .. ")")
        if src == "default" then
            out("hint: `world alpha` to set, `world clear` to remove override")
        end
        return
    end

    if sub == "clear" then
        local s = readState()
        s.world_id = nil
        writeState(s)
        local w, src = currentWorld()
        out("world override cleared. effective: " .. w .. " (" .. src .. ")")
        out("(restart rpcd or reboot for the change to take effect)")
        return
    end

    if not isValid(sub) then
        err("world: id must be 1..64 chars of [A-Za-z0-9_.-]")
        return
    end

    local s = readState()
    s.world_id = sub
    if not writeState(s) then
        err("world: failed to write " .. STATE)
        return
    end
    out("world set to: " .. sub)
    out("(restart rpcd or reboot for the change to take effect)")
end

return M
