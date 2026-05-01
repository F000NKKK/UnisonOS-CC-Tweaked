-- Files — minimal directory browser.

local Buffer = dofile("/unison/ui/buffer.lua")

return {
    id = "files",
    title = "Files",
    roles = { "any" },
    make = function(geom)
        local cwd = "/"
        local entries = {}
        local sel = 1
        local offset = 0

        local function refresh()
            entries = {}
            entries[1] = { name = "..", isDir = true, parent = true }
            local ok, list = pcall(fs.list, cwd)
            if not ok or not list then return end
            table.sort(list)
            for _, name in ipairs(list) do
                local p = (cwd == "/" and "" or cwd) .. "/" .. name
                local isDir = fs.isDir(p)
                entries[#entries + 1] = {
                    name = name,
                    isDir = isDir,
                    size = isDir and 0 or fs.getSize(p),
                }
            end
            if sel > #entries then sel = #entries end
            if sel < 1 then sel = 1 end
        end

        refresh()

        local function path(e)
            if e.parent then
                if cwd == "/" then return "/" end
                return cwd:match("^(.*/)[^/]+/?$") or "/"
            end
            local sep = (cwd == "/") and "" or "/"
            return cwd .. sep .. e.name
        end

        return {
            title = "Files — " .. cwd,
            x = geom.x, y = geom.y, w = geom.w, h = geom.h,
            render = function(self, _)
                self.title = "Files — " .. cwd
                local b = Buffer.new(term.current())
                local listH = self.h - 3
                if sel < offset + 1 then offset = sel - 1 end
                if sel > offset + listH then offset = sel - listH end
                for i = 1, listH do
                    local idx = i + offset
                    local e = entries[idx]
                    if e then
                        local icon = e.isDir and "[ ]" or "   "
                        local label = icon .. " " .. e.name
                        if not e.isDir then
                            label = label .. string.rep(" ",
                                math.max(0, self.w - 2 - #label - 8)) ..
                                string.format("%6dB", e.size)
                        end
                        if #label > self.w - 2 then label = label:sub(1, self.w - 2) end
                        label = label .. string.rep(" ", self.w - 2 - #label)
                        if idx == sel then
                            b:text(self.x + 1, self.y + i, label, colors.black, colors.yellow)
                        else
                            b:text(self.x + 1, self.y + i, label,
                                e.isDir and colors.lightBlue or colors.white,
                                colors.black)
                        end
                    else
                        b:text(self.x + 1, self.y + i, string.rep(" ", self.w - 2),
                            colors.white, colors.black)
                    end
                end
                b:text(self.x + 1, self.y + self.h - 2, " Enter:open  Backspace:up ",
                    colors.lightGray, colors.black)
            end,
            onEvent = function(self, ev)
                if ev[1] == "key" then
                    local k = ev[2]
                    if k == keys.up        and sel > 1            then sel = sel - 1; return "consumed" end
                    if k == keys.down      and sel < #entries     then sel = sel + 1; return "consumed" end
                    if k == keys.pageUp    then sel = math.max(1, sel - 10); return "consumed" end
                    if k == keys.pageDown  then sel = math.min(#entries, sel + 10); return "consumed" end
                    if k == keys.backspace then
                        if cwd ~= "/" then cwd = cwd:match("^(.*)/[^/]+$") or "/"; if cwd == "" then cwd = "/" end end
                        sel = 1; offset = 0; refresh(); return "consumed"
                    end
                    if k == keys.enter then
                        local e = entries[sel]
                        if not e then return "consumed" end
                        local p = path(e)
                        if e.isDir then
                            cwd = p; sel = 1; offset = 0; refresh()
                        end
                        return "consumed"
                    end
                end
            end,
        }
    end,
}
