-- unison.lib.rpcd.acl — per-message-type RPC firewall.
--
-- Two layers of rules merge into one allowed(msgType, fromId) decision:
--   * static config:   unison.config.rpc_acl  (set in /unison/config.lua)
--   * runtime override:/unison/state/acl.json (set via the `acl` shell)
--
-- The override wins so a runtime change takes effect without a reboot.
-- The state file is cached for 1 s so high-throughput RPC streams
-- don't beat the disk on every dispatch.
--
-- Rule grammar (per message type):
--   true / "*"                       allow everyone
--   false                            deny everyone
--   "<id>"                           allow only that device id
--   { allow = { id... } }            whitelist
--   { deny  = { id... } }            blacklist
--   { id... }                        whitelist (positional)
--   { default = bool }               fallback when no list entries hit

local M = {}

local CACHE_TTL_MS = 1000
local _cache, _cacheTs = nil, 0

local function listHas(list, value)
    if type(list) ~= "table" then return false end
    local s = tostring(value or "")
    for _, v in ipairs(list) do
        local x = tostring(v)
        if x == "*" or x == s then return true end
    end
    return false
end

local function override()
    local now = os.epoch and os.epoch("utc") or 0
    if _cache and (now - _cacheTs) < CACHE_TTL_MS then return _cache end
    local lib = unison and unison.lib
    local data = {}
    if lib and lib.fs and fs.exists("/unison/state/acl.json") then
        data = lib.fs.readJson("/unison/state/acl.json") or {}
    end
    _cache, _cacheTs = data, now
    return data
end

function M.allowed(msgType, fromId)
    local cfg = unison and unison.config and unison.config.rpc_acl
    local rule = override()[msgType] or override()["*"]
    if rule == nil and type(cfg) == "table" then
        rule = cfg[msgType] or cfg["*"]
    end
    if rule == nil       then return true  end
    if rule == true      then return true  end
    if rule == false     then return false end
    local from = tostring(fromId or "")
    if type(rule) == "string" then
        return rule == "*" or rule == from
    end
    if type(rule) == "table" then
        if listHas(rule.deny, from) then return false end
        if rule.allow ~= nil then return listHas(rule.allow, from) end
        if #rule > 0 then return listHas(rule, from) end
        if rule.default ~= nil then return not not rule.default end
    end
    return true
end

-- Map dispatch types onto the conventional reply type so the caller
-- gets a consistent shape on ACL denial.
function M.replyTypeFor(msgType)
    if msgType == "exec" then return "exec_reply" end
    if msgType == "pilot" then return "pilot_reply" end
    if msgType == "craft_order" or msgType == "recipe_list"
       or msgType == "recipe_add" then
        return "craft_reply"
    end
    if msgType:match("^mine_") then return "mine_reply" end
    if msgType:match("^farm_") then return "farm_reply" end
    if msgType:match("^scanner_") then return "scanner_reply" end
    if msgType:match("^storage_") then return "storage_reply" end
    if msgType:match("^atlas_") then return "atlas_reply" end
    if msgType:match("^patrol_") then return "patrol_reply" end
    if msgType:match("^redstone_") then return "redstone_reply" end
    if msgType:match("^home_") then return "home_reply" end
    if msgType:match("^selection_") then return "selection_reply" end
    if msgType:match("^worker_") then return "worker_reply" end
    if msgType == "mine_done" then return "mine_done_reply" end
    if msgType == "mine_assign" or msgType == "mine_abort" then return "mine_reply" end
    return nil
end

-- For tests / debugging.
M._listHas  = listHas
M._override = override

return M
