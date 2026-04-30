local M = { desc = "Print current working directory", usage = "pwd" }
function M.run(ctx) print(ctx.cwd or "/") end
return M
