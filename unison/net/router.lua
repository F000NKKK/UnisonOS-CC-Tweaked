local log = dofile("/unison/kernel/log.lua")

local M = {}

local STATE_DIR = "/unison/state"
local REGISTRY_FILE = STATE_DIR .. "/registry.lua"

local neighbors = {}
local registry = {}

local function ensureDir() if not fs.exists(STATE_DIR) then fs.makeDir(STATE_DIR) end end

local function readTable(path)
    if not fs.exists(path) then return {} end
    local h = fs.open(path, "r")
    local raw = h.readAll(); h.close()
    local ok, t = pcall(textutils.unserialize, raw)
    return (ok and type(t) == "table") and t or {}
end

local function writeTable(path, t)
    ensureDir()
    local h = fs.open(path, "w")
    h.write(textutils.serialize(t))
    h.close()
end

function M.load()
    registry = readTable(REGISTRY_FILE)
end

function M.save()
    writeTable(REGISTRY_FILE, registry)
end

function M.observeNeighbor(nodeId, modemName, distance)
    neighbors[nodeId] = {
        modem = modemName,
        distance = distance,
        last_seen = os.epoch("utc"),
    }
end

function M.neighbors() return neighbors end

function M.registerNode(nodeId, info)
    registry[nodeId] = registry[nodeId] or {}
    for k, v in pairs(info or {}) do registry[nodeId][k] = v end
    registry[nodeId].registered_at = registry[nodeId].registered_at or os.epoch("utc")
    M.save()
end

function M.touchNode(nodeId)
    registry[nodeId] = registry[nodeId] or {}
    registry[nodeId].last_seen = os.epoch("utc")
end

function M.revoke(nodeId)
    if not registry[nodeId] then return false end
    registry[nodeId].revoked = true
    M.save()
    return true
end

function M.isRevoked(nodeId)
    return registry[nodeId] and registry[nodeId].revoked or false
end

function M.knownNodes() return registry end

function M.markStale(thresholdMs)
    local now = os.epoch("utc")
    for id, info in pairs(registry) do
        if info.last_seen and now - info.last_seen > thresholdMs then
            info.status = "STALE"
        else
            info.status = "OK"
        end
    end
end

return M
