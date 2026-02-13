local M = {}

-- Sends request for host's filetree
function M.list_remote_files()
	local events = require("cesp.events")
	events.send_event({
		event = "request_files",
	})
end

local function open_with_telescope(files, on_select)
	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local themes = require("telescope.themes")
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")

	local opts = themes.get_ivy({
		prompt_title = "Remote files",
	})

	pickers
		.new(opts, {
			finder = finders.new_table({
				results = files,
			}),
			sorter = conf.generic_sorter({}),
			attach_mappings = function(prompt_bufnr)
				actions.select_default:replace(function()
					local selection = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if selection then
						-- selection[1] is the file path string
						on_select(selection[1])
					end
				end)
				return true
			end,
		})
		:find()
end

-- Used when Telescope is not installed. Asks for input first to filter, then selects
local function open_with_fallback(files, on_select)
	vim.ui.input(
		{ prompt = "Filter files (leave empty for all): " },
		function(input)
			-- Escape
			if input == nil then
				return
			end

			-- Filter results
			local filtered = files
			if input ~= "" then
				filtered = vim.tbl_filter(function(file)
					-- Simple case-insensitive match
					return file:lower():find(input:lower(), 1, true) ~= nil
				end, files)
			end

			if #filtered == 0 then
				print("No matches found")
				return
			end

			vim.ui.select(filtered, {
				prompt = "Select remote file:",
				kind = "file",
			}, function(choice)
				if choice then
					on_select(choice)
				end
			end)
		end
	)
end

function M.open_file_browser(files, on_select)
	local has_telescope, _ = pcall(require, "telescope")

	if has_telescope then
		open_with_telescope(files, on_select)
	else
		open_with_fallback(files, on_select)
	end
end

function M.open_remote_file(path, content, on_complete)
	local utils = require("cesp.utils")

	vim.schedule(function()
		local target_rel_path = path

		-- Search for existing buffers
		local buf = utils.find_buffer_by_rel_path(path)

		-- If not found, create one
		if not buf then
			buf = vim.api.nvim_create_buf(true, true)
			pcall(vim.api.nvim_buf_set_name, buf, target_rel_path)

			vim.bo[buf].buftype = "acwrite"
			vim.bo[buf].swapfile = false
			vim.bo[buf].bufhidden = "hide"

			local ft = vim.filetype.match({ filename = target_rel_path })
			if ft then
				vim.bo[buf].filetype = ft
			end

			-- This needs to be a acwrite buf to listen for write events
			-- but it should never complain about not written files
			-- TODO: Get rid of this nasty piece of code
			vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
				buffer = buf,
				callback = function()
					vim.bo[buf].modified = false
				end,
			})

			-- TODO: Try to forcibly attach lsp to the buffer
		end

		local lines = vim.split(content, "\n", { plain = true })
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.api.nvim_set_current_buf(buf)

		if on_complete then
			on_complete(buf)
		end
	end)
end

return M
