-- unison.lib.rpcd.metrics — collect everything that goes into the
-- per-device heartbeat: capabilities, fuel, inventory, redstone IO,
-- mine job state, position (gpsnet host / vanilla GPS / saved tower
-- coords). Was inline in services/rpcd.lua and dwarfed the dispatch
-- logic; lives in lib/ now so the service is just orchestration.
--
-- Pure function: collect() returns a fresh table every call.

local M = {}

local GPS_STATE_FILE = "/unison/state/gpsnet.lua"
local MINE_JOB_FILE  = "/unison/state/mine/job.json"
local TOWER_FILE     = "/unison/state/gps-host.json"

local SIDES = { "front", "back", "left", "right", "top", "bottom" }

local function iRound(n)
    n = tonumber(n) or 0
    if n >= 0 then return math.floor(n + 0.5) end
    return math.ceil(n - 0.5)
end

local function loadGpsnetState()
    if not fs.exists(GPS_STATE_FILE) then return nil end
    local fn = loadfile(GPS_STATE_FILE)
    if not fn then return nil end
    local ok, t = pcall(fn)
    if not ok or type(t) ~= "table" then return nil end
    return t
end

----------------------------------------------------------------------
-- Sub-collectors (one per metric group). Each writes into the shared
-- `metrics` table; keeps collect() readable.
----------------------------------------------------------------------

local function capabilities()
    return {
        rpc     = true,
        turtle  = turtle and true or false,
        gps     = gps and true or false,
        modem   = peripheral and peripheral.find
                  and (peripheral.find("modem") ~= nil) or false,
        monitor = peripheral and peripheral.find
                  and (peripheral.find("monitor") ~= nil) or false,
    }
end

local function turtleStats(metrics)
    if not turtle then return end
    metrics.fuel = turtle.getFuelLevel()
    local used = 0
    for i = 1, 16 do
        if turtle.getItemCount(i) > 0 then used = used + 1 end
    end
    metrics.inventory_used = used
end

local function redstoneIO(metrics)
    if not (redstone and redstone.getAnalogInput) then return end
    local rs = { inputs = {}, outputs = {} }
    for _, side in ipairs(SIDES) do
        local oki, vi = pcall(redstone.getAnalogInput, side)
        if oki then rs.inputs[side] = vi end
        local oko, vo = pcall(redstone.getAnalogOutput, side)
        if oko then rs.outputs[side] = vo end
    end
    metrics.redstone = rs
end

local function mineJob(metrics)
    if not fs.exists(MINE_JOB_FILE) then return end
    local lib = unison and unison.lib
    local j = lib and lib.fs and lib.fs.readJson(MINE_JOB_FILE)
    if type(j) ~= "table" then return end
    metrics.mine = {
        phase      = j.phase,
        dug        = j.dug,
        pos        = j.pos,
        shape      = j.shape,
        started_at = j.started_at,
        error      = j.error,
    }
end

-- Try, in order: gpsnet host, vanilla gps.locate, saved tower coords.
local function position(metrics)
    local state = loadGpsnetState() or {}
    local mode = state.mode == "host" and "host" or "auto"
    metrics.gpsnet = { mode = mode }
    metrics.capabilities.gps_http = true

    local hosted = mode == "host" and state.host
    if hosted and hosted.x and hosted.y and hosted.z then
        metrics.position = {
            x = iRound(hosted.x),
            y = iRound(hosted.y),
            z = iRound(hosted.z),
        }
        metrics.position_source = "host"
        metrics.gpsnet.host = true
        metrics.capabilities.gps_http_host = true
        return
    end

    local lib = unison and unison.lib
    local gotFix = false
    if lib and lib.gps then
        local x, y, z, src = lib.gps.locate("self", { timeout = 0.5 })
        if x and src == "gps" then
            metrics.position = {
                x = iRound(x), y = iRound(y), z = iRound(z),
            }
            metrics.position_source = "gps"
            gotFix = true
        end
    end
    -- Tower fallback: a host configured via gps-tower has its coords
    -- saved locally even though it can't triangulate itself.
    if not gotFix and lib and lib.fs and fs.exists(TOWER_FILE) then
        local saved = lib.fs.readJson(TOWER_FILE)
        if type(saved) == "table" and saved.x and saved.y and saved.z then
            metrics.position = {
                x = iRound(saved.x), y = iRound(saved.y), z = iRound(saved.z),
            }
            metrics.position_source = "tower"
        end
    end
end

----------------------------------------------------------------------
-- Public
----------------------------------------------------------------------

function M.collect()
    local metrics = {
        uptime = math.floor(
            (os.epoch("utc") - (UNISON.boot_time or 0)) / 1000),
        role = unison and unison.role or nil,
    }
    metrics.capabilities = capabilities()
    turtleStats(metrics)
    redstoneIO(metrics)
    mineJob(metrics)
    position(metrics)

    -- Home point (world-anchored) so the dispatcher can route this
    -- node back after a task. nil if no home was ever set.
    local lib = unison and unison.lib
    if lib and lib.home then
        local h = lib.home.get()
        if h then
            metrics.home = {
                x = h.x, y = h.y, z = h.z,
                facing = h.facing,
                label  = h.label,
                explicit = h.set_by ~= nil and h.set_by ~= "auto",
            }
        end
    end

    -- Device "kind" — config.lua wins, then /unison/state/worker.json,
    -- then omit (daemon default is "mining").
    local kind = unison and unison.config and unison.config.kind
    if not kind and lib and lib.fs and lib.fs.readJson then
        local w = lib.fs.readJson("/unison/state/worker.json")
        if type(w) == "table" and w.kind then kind = w.kind end
    end
    if kind then metrics.kind = tostring(kind) end

    return metrics
end

return M
