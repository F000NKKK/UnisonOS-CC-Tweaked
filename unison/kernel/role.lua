local M = {}

function M.detect(cfg)
    if cfg and cfg.is_master then return "master" end
    if turtle then return "turtle" end
    if pocket then return "pocket" end
    return "computer"
end

function M.nodeName(cfg)
    if cfg and cfg.node_name and cfg.node_name ~= "" then
        return cfg.node_name
    end
    return M.detect(cfg) .. "-" .. tostring(os.getComputerID())
end

return M
