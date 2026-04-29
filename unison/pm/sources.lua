-- Source resolution for UPM.
--
-- Sources are HTTP base URLs. The registry lives at <base>/apps/registry.json,
-- packages at <base>/apps/packages/<name>/<version>/<file>. Sources are tried
-- in order; the first that responds wins.

local log = dofile("/unison/kernel/log.lua")

local DEFAULT_SOURCES = {
    "http://upm.hush-vp.ru:9273",
    "https://raw.githubusercontent.com/F000NKKK/UnisonOS-CC-Tweaked/master",
}

local M = {}

function M.list()
    if unison and unison.config and type(unison.config.pm_sources) == "table" then
        return unison.config.pm_sources
    end
    return DEFAULT_SOURCES
end

local function fetchUrl(url)
    if not http then return nil, "http disabled" end
    local sep = url:find("?", 1, true) and "&" or "?"
    local bust = url .. sep .. "_=" .. tostring(os.epoch("utc"))
    local headers = { ["Cache-Control"] = "no-cache", ["Pragma"] = "no-cache" }
    local r, err = http.get(bust, headers)
    if not r then return nil, "http error: " .. tostring(err) end
    local code = r.getResponseCode and r.getResponseCode() or 200
    if code >= 400 then r.close(); return nil, "http " .. code end
    local body = r.readAll()
    r.close()
    return body
end

function M.fetchOne(url)
    return fetchUrl(url)
end

function M.fetchRel(rel)
    local lastErr
    for _, base in ipairs(M.list()) do
        local body, err = fetchUrl(base .. "/" .. rel)
        if body then return body, base end
        lastErr = err
        log.debug("upm", "source " .. base .. " failed for " .. rel .. ": " .. tostring(err))
    end
    return nil, lastErr or "all sources failed"
end

function M.fetchRegistry()
    return M.fetchRel("apps/registry.json")
end

function M.fetchManifest(name, version)
    return M.fetchRel("apps/packages/" .. name .. "/" .. version .. "/manifest.lua")
end

function M.fetchPackageFile(name, version, file)
    return M.fetchRel("apps/packages/" .. name .. "/" .. version .. "/" .. file)
end

return M
