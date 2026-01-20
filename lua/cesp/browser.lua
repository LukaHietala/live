local M = {}
local ns_id = vim.api.nvim_create_namespace("RemoteFileBrowserSearch")

local function get_match_score(query, path)
	-- If query is empty give score of 1
	if query == "" then
		return 1, {}
	end

	local q_lower, p_lower = query:lower(), path:lower()
	local q_len, p_len = #q_lower, #p_lower

	-- If query is near "boundary" "_.-/" return true
	-- This is to give higher score "m" in "path/mirri.txt" rather than "r"
	local function is_boundary(pos)
		if pos == 1 then
			return true
		end
		local prev_char = p_lower:sub(pos - 1, pos - 1)
		return prev_char:find("[%s%/_%.%-%\\]") ~= nil
	end

	-- Exact match (most points)
	local last_s, last_e
	local s_index = 1
	while true do
		local start_pos, end_pos = p_lower:find(q_lower, s_index, true)
		-- No more matches
		if not start_pos then
			break
		end
		last_s, last_e = start_pos, end_pos
		s_index = start_pos + 1
	end

	-- If exact query found, score it
	-- Base score 95, +5 if near boundary -[distance from end]
	if last_s then
		local match_positions = {}
		for i = last_s, last_e do
			table.insert(match_positions, i - 1)
		end

		local bonus = is_boundary(last_s) and 5 or 0
		return (95 - (p_len - last_s)) + bonus, match_positions
	end

	-- Amateur fuzzy match (right to left)
	local match_positions = {}
	local last_found = p_len
	local total_pos = 0
	local boundary_matches = 0

	-- Iterate backwards
	for i = q_len, 1, -1 do
		local char = q_lower:sub(i, i)
		local found_at = nil

		for j = last_found, 1, -1 do
			if p_lower:sub(j, j) == char then
				found_at = j
				-- If we found a boundary match, we prefer it, but for simplicity
				-- we'll take the rightmost occurrence
				break
			end
		end

		-- If no fuzzy match
		if not found_at then
			return 0
		end

		-- If on boundary add 1 boundary match (will be multiplied later)
		if is_boundary(found_at) then
			boundary_matches = boundary_matches + 1
		end

		table.insert(match_positions, 1, found_at - 1)
		total_pos = total_pos + found_at
		last_found = found_at - 1
	end

	-- Calculate fuzzy score (50-65)
	-- avg_pos_score: up to 10 points (favoring end of path)
	-- boundary_bonus: up to 5 points
	local avg_pos_score = (total_pos / q_len) / p_len * 10
	local boundary_bonus = (boundary_matches / q_len) * 5

	return 50 + avg_pos_score + boundary_bonus, match_positions
end

function M.open_file_browser(files, on_select)
	-- Buffer where selected file will be "opened"
	local target_win = vim.api.nvim_get_current_win()
	-- Unlisted scratch buffer for file browser
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].buftype = "nofile"

	local win = vim.api.nvim_open_win(buf, true, {
		-- TODO: Add split and other settings to config, non-floating for simplicity
		split = "above",
		height = math.floor(vim.o.lines / 2) - vim.opt.cmdheight:get() - 1,
		style = "minimal",
	})
	vim.wo[win].cursorline = true
	vim.api.nvim_set_hl(0, "SearchMatch", { fg = "#fc863f", bold = true })

	local function render()
		if not vim.api.nvim_buf_is_valid(buf) then
			return
		end
		local query = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""

		-- Filter, score, and sort. Ignore if score is zero (nothing matches)
		local results = vim.iter(files)
			:map(function(file)
				local score, indices = get_match_score(query, file)
				return { name = file, score = score, indices = indices }
			end)
			:filter(function(item)
				return item.score > 0
			end)
			:totable()

		table.sort(results, function(a, b)
			return a.score > b.score
		end)

		-- Show results
		local lines = vim.iter(results)
			:map(function(item)
				return item.name
			end)
			:totable()
		vim.api.nvim_buf_set_lines(buf, 1, -1, false, lines)

		-- Apply highlights using extmarks
		vim.api.nvim_buf_clear_namespace(buf, ns_id, 1, -1)
		for i, item in ipairs(results) do
			-- Row is 'i' because the first result is on the second line (index 1)
			-- ... Neovim's line numbers are 0 index and lua is 1 index :katti:
			local row = i
			for _, col in ipairs(item.indices or {}) do
				vim.api.nvim_buf_set_extmark(buf, ns_id, row, col, {
					end_row = row,
					end_col = col + 1,
					hl_group = "SearchMatch",
				})
			end
		end
	end

	-- Initial render, leave first line for search
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
	render()
	vim.cmd("startinsert!")

	-- Listen for search input
	vim.api.nvim_create_autocmd("TextChangedI", {
		buffer = buf,
		callback = render,
	})

	local function select_file()
		local row = vim.api.nvim_win_get_cursor(win)[1]
		-- If on search, pick the first result (line 2). Otherwise pick current line
		local target_row = row == 1 and 2 or row
		-- Rip the path straight out of the line
		local file = vim.api.nvim_buf_get_lines(
			buf,
			target_row - 1,
			target_row,
			false
		)[1]

		if file and file ~= "" then
			vim.api.nvim_win_close(win, true)
			vim.api.nvim_set_current_win(target_win)
			on_select(file)
		end
	end

	local opts = { buffer = buf, silent = true }
	vim.keymap.set({ "i", "n" }, "<CR>", select_file, opts)
	vim.keymap.set({ "i", "n" }, "<Esc>", function()
		vim.api.nvim_win_close(win, true)
	end, opts)
	vim.keymap.set("i", "<C-j>", "<Down>", opts)
	vim.keymap.set("i", "<C-k>", "<Up>", opts)
end

return M
