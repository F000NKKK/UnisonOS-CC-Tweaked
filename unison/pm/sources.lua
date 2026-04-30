-- UPM source resolution. Sources are HTTP base URLs; the registry lives at
-- <base>/apps/registry.json, packages at <base>/apps/packages/<n>/<v>/<f>.

local httpLib = dofile("/unison/lib/http.lua")
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

function M.fetchOne(url)
    return httpLib.get(url)
end

function M.fetchRel(rel)
    local body, srcOrErr = httpLib.getFromSources(M.list(), rel)
    if not body then
        log.debug("upm", "fetch " .. rel .. ": " .. tostring(srcOrErr))
    end
    return body, srcOrErr
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
