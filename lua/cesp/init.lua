local config = require("cesp.config").config
local browser = require("cesp.browser")
local buffer = require("cesp.buffer")
local network = require("cesp.network")

local M = {}

function M.setup(opts)
	config = vim.tbl_deep_extend("force", config, opts or {})

	vim.api.nvim_create_user_command("CespJoin", function(args)
		local ip = args.args ~= "" and args.args or "127.0.0.1"
		network.start_client(ip)
	end, { nargs = "?" })

	vim.api.nvim_create_user_command("CespExplore", function()
		browser.list_remote_files()
	end, {})

	vim.api.nvim_create_user_command("CespPending", function()
		buffer.review_pending()
	end, {})

	vim.api.nvim_create_autocmd("VimLeavePre", {
		callback = function()
			network.stop()
		end,
	})
end

return M
