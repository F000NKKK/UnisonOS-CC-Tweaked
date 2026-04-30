-- unison.lib.http — HTTP fetch helpers with cache-busting and multi-source
-- failover. Used by OS code and exposed to apps with the 'http' permission.

local M = {}

local function bust(url)
    local sep = url:find("?", 1, true) and "&" or "?"
    return url .. sep .. "_=" .. tostring(os.epoch("utc"))
end

local function defaultHeaders(extra)
    local h = {
        ["Cache-Control"] = "no-cache",
        ["Pragma"] = "no-cache",
    }
    if extra then for k, v in pairs(extra) do h[k] = v end end
    return h
end

-- GET with cache-bust; returns body, status_code or nil, err.
function M.get(url, headers)
    if not http then return nil, "http disabled" end
    local r, err = http.get(bust(url), defaultHeaders(headers))
    if not r then return nil, "http error: " .. tostring(err) end
    local code = r.getResponseCode and r.getResponseCode() or 200
    if code >= 400 then r.close(); return nil, "http " .. code end
    local body = r.readAll()
    r.close()
    return body, code
end

-- Try every source in order (each is a base URL). Returns body, source on
-- first success, or nil, last_error on total failure.
function M.getFromSources(sources, rel)
    local lastErr
    for _, base in ipairs(sources or {}) do
        local body, err = M.get(base .. "/" .. rel)
        if body then return body, base end
        lastErr = err
    end
    return nil, lastErr or "all sources failed"
end

-- POST with optional table body (auto-encoded as JSON). Returns body, code.
function M.post(url, body, headers)
    if not http then return nil, "http disabled" end
    headers = defaultHeaders(headers)
    headers["Content-Type"] = headers["Content-Type"] or "application/json"
    if type(body) == "table" then body = textutils.serializeJSON(body) end
    local r, err = http.post(url, body or "", headers)
    if not r then return nil, "http error: " .. tostring(err) end
    local code = r.getResponseCode and r.getResponseCode() or 200
    local resp = r.readAll()
    r.close()
    if code >= 400 then return nil, "http " .. code .. ": " .. resp end
    return resp, code
end

return M
