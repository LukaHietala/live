local browser = require("cesp.browser")
local buffer = require("cesp.buffer")
local events = require("cesp.events")
local network = require("cesp.network")

local M = {}

function M.setup(opts)
	local config_mod = require("cesp.config")
	config_mod.config =
		vim.tbl_deep_extend("force", config_mod.config, opts or {})

	vim.api.nvim_create_user_command("CespJoin", function(args)
		local ip = args.args ~= "" and args.args or "127.0.0.1"
		vim.ui.select({ "Host", "Client" }, {
			prompt = "Join session as:",
		}, function(choice)
			if not choice then
				print("Join cancelled")
				return
			end

			local is_host = (choice == "Host")
			if is_host then
				vim.ui.select({ "Yes", "No" }, {
					prompt = "Allow clients to save files on your machine (:w)? (dangerous)",
				}, function(allow_write)
					if not allow_write then
						print("Join cancelled")
						return
					end

					events.allow_remote_write = (allow_write == "Yes")

					network.start_client(ip, is_host)
				end)
			else
				network.start_client(ip, is_host)
			end
		end)
	end, { nargs = "?" })

	vim.api.nvim_create_user_command("CespLeave", function()
		if network.handle == nil then
			print("Not connected")
			return
		end

		network.stop()
	end, {})

	vim.api.nvim_create_user_command("CespExplore", function()
		if events.state.is_host then
			print("For clients only")
			return
		end
		browser.list_remote_files()
	end, {})

	vim.api.nvim_create_user_command("CespPending", function()
		if not events.state.is_host then
			print("For host only")
			return
		end
		buffer.review_pending()
	end, {})

	vim.api.nvim_create_autocmd("VimLeavePre", {
		callback = function()
			network.stop()
		end,
	})
end

return M
