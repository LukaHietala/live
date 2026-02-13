local utils = require("cesp.utils")

local M = {}
function M.check()
	local root = vim.fs.normalize(utils.get_project_root())
	vim.health.info("Current project root: " .. root)
end
return M
