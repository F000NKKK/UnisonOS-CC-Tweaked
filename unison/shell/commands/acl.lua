local M = {
    desc = "Manage the per-message-type RPC ACL (who can send what to this device)",
    usage = "acl <list|set|clear|reset>  see `acl help` for examples",
}

local fsLib = unison and unison.lib and unison.lib.fs or dofile("/unison/lib/fs.lua")
local STATE_FILE = "/unison/state/acl.json"

local function load()
    return fsLib.readJson(STATE_FILE) or {}
end
local function save(t)
    if not fs.exists("/unison/state") then fs.makeDir("/unison/state") end
    fsLib.writeJson(STATE_FILE, t or {})
end

local function help()
    print("acl — per-message-type RPC firewall")
    print("")
    print("Configured in /unison/state/acl.json (this device only) AND")
    print("inherited from unison.config.rpc_acl (set in /unison/config.lua).")
    print("")
    print("Rules per message type:")
    print("  true        : allow everyone")
    print("  false       : deny everyone")
    print("  '<id>'      : allow only that device id (string)")
    print("  '*'         : same as true")
    print("  { allow={ids...}, deny={ids...}, default=bool }")
    print("")
    print("Commands:")
    print("  acl list                       show current effective rules")
    print("  acl set <type> allow <id...>   permit only listed senders")
    print("  acl set <type> deny  <id...>   block listed senders, allow rest")
    print("  acl set <type> any             allow everyone (true)")
    print("  acl set <type> none            deny everyone (false)")
    print("  acl clear <type>               remove the override")
    print("  acl reset                      wipe all overrides on this device")
    print("")
    print("Examples:")
    print("  acl set mine_order allow 5 7   # only nodes 5 and 7 can dispatch mining")
    print("  acl set exec deny 4            # block PC 4 from running exec")
    print("  acl set scanner_order any      # public scanning")
end

local function fmtRule(rule)
    if rule == nil then return "(unset, defaults to allow)" end
    if rule == true then return "any" end
    if rule == false then return "none" end
    if type(rule) == "string" then return "id=" .. rule end
    if type(rule) == "table" then
        local parts = {}
        if rule.allow then parts[#parts+1] = "allow=" .. table.concat(rule.allow, ",") end
        if rule.deny  then parts[#parts+1] = "deny="  .. table.concat(rule.deny,  ",") end
        if rule.default ~= nil then parts[#parts+1] = "default=" .. tostring(rule.default) end
        if #parts == 0 then
            for _, v in ipairs(rule) do parts[#parts+1] = tostring(v) end
            return "ids=" .. table.concat(parts, ",")
        end
        return table.concat(parts, " ")
    end
    return tostring(rule)
end

local function cmdList()
    local cfg = (unison and unison.config and unison.config.rpc_acl) or {}
    local override = load()
    -- Merge for display.
    local seen = {}
    for k in pairs(cfg) do seen[k] = true end
    for k in pairs(override) do seen[k] = true end
    local keys = {}; for k in pairs(seen) do keys[#keys+1] = k end
    table.sort(keys)
    print(string.format("%-22s %-22s %s", "TYPE", "STATE-FILE", "CONFIG"))
    if #keys == 0 then
        print("  (no rules; everything is allowed by default)")
    end
    for _, k in ipairs(keys) do
        print(string.format("%-22s %-22s %s",
            k:sub(1, 22),
            fmtRule(override[k]):sub(1, 22),
            fmtRule(cfg[k]):sub(1, 32)))
    end
end

local function cmdSet(args)
    local typ = args[1]
    local kind = args[2]
    if not (typ and kind) then printError("usage: acl set <type> <allow|deny|any|none> [ids...]"); return end
    local override = load()
    if kind == "any" then override[typ] = true
    elseif kind == "none" then override[typ] = false
    elseif kind == "allow" or kind == "deny" then
        local ids = {}; for i = 3, #args do ids[#ids+1] = args[i] end
        local rule = {}
        rule[kind] = ids
        override[typ] = rule
    else printError("kind must be allow|deny|any|none"); return end
    save(override)
    print("acl: " .. typ .. " ⇒ " .. fmtRule(override[typ]))
end

local function cmdClear(args)
    local typ = args[1]
    if not typ then printError("usage: acl clear <type>"); return end
    local override = load()
    override[typ] = nil
    save(override)
    print("acl: cleared " .. typ)
end

function M.run(ctx, args)
    local sub = args[1] or "list"
    table.remove(args, 1)
    if sub == "list" then cmdList()
    elseif sub == "set" then cmdSet(args)
    elseif sub == "clear" or sub == "rm" then cmdClear(args)
    elseif sub == "reset" then save({}); print("acl: all overrides cleared")
    elseif sub == "help" or sub == "-h" or sub == "--help" then help()
    else help() end
end

return M
