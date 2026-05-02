-- `kind` — get or set the worker kind tag for this device.
--
-- The kind is sent to the dispatcher on worker_register so it can
-- filter which workers get mining vs other job types.
-- Stored in /unison/state/worker.json (overrides config.lua kind).
--
-- Usage:
--   kind                  show current kind
--   kind <value>          set kind (e.g. "mining", "farming", "any")
--   kind clear            remove kind override (falls back to config or "mining")

local M = {
    desc  = "Get or set this device's worker kind (mining/farming/any/…)",
    usage = "kind [<value> | clear]",
}

local STATE = "/unison/state/worker.json"

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
    local h = fs.open(STATE, "w"); if not h then return false end
    h.write(textutils.serializeJSON(t)); h.close(); return true
end

local function currentKind()
    local w = readState()
    if w.kind then return w.kind, "state" end
    local cfgKind = unison and unison.config and unison.config.kind
    if cfgKind then return cfgKind, "config" end
    return "mining", "default"
end

function M.run(ctx, args)
    local io = unison and unison.stdio
    local function out(s) if io then io.print(s) else print(s) end end
    local function err(s) if io then io.printError(s) else printError(s) end end

    local sub = args[1]

    if not sub then
        local k, src = currentKind()
        out("kind: " .. k .. "  (" .. src .. ")")
        return
    end

    if sub == "clear" then
        local w = readState()
        w.kind = nil
        writeState(w)
        local k, src = currentKind()
        out("kind override cleared. effective: " .. k .. " (" .. src .. ")")
        return
    end

    -- Set new kind
    local w = readState()
    w.kind = sub
    if not writeState(w) then
        err("kind: failed to write " .. STATE)
        return
    end
    out("kind set to: " .. sub)
    out("(restart mine-worker for the change to take effect)")
end

return M
