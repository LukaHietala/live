local M = {}

-- List of buffer that have nvim_buf listener
M.attached = {}
-- True if buffer changes are happening
M.is_applying = false
-- List of pending changes from other clients on non-open buffers
M.pending = {}

local utils = require("cesp.utils")

-- Applies a single change object to a buffer
function M.apply_change(buf, change)
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end

	M.is_applying = true
	local ok, err = pcall(
		vim.api.nvim_buf_set_lines,
		buf,
		change.first,
		change.old_last,
		false,
		change.lines
	)
	M.is_applying = false

	if not ok then
		print("Error applying change: " .. tostring(err))
	end
end

-- Adds changes to pending. Happens if host doesn't have same buffer open
function M.add_pending(path, change)
	if not M.pending[path] then
		M.pending[path] = {}
	end
	table.insert(M.pending[path], change)
end

-- Opens diff between disk and pending content
function M.open_pending_diff(path)
	local abs_path = utils.get_abs_path(path)
	local disk_content = utils.read_file(abs_path)
	local pending_content = utils.get_file_content(path, M.pending[path])

	local buf = vim.api.nvim_create_buf(true, true)
	pcall(vim.api.nvim_buf_set_name, buf, path .. " [pending]")

	local diff_text = vim.text.diff(disk_content or "", pending_content, {
		result_type = "unified",
		ctxlen = 3,
	})

	if diff_text == "" then
		diff_text = "No changes"
	end

	vim.api.nvim_buf_set_lines(
		buf,
		0,
		-1,
		false,
		vim.split(tostring(diff_text), "\n")
	)

	vim.bo[buf].filetype = "diff"
	vim.bo[buf].buftype = "nofile"

	vim.api.nvim_set_current_buf(buf)

	return buf
end

function M.review_pending()
	-- Get all pending change paths
	local paths = {}
	for path, _ in pairs(M.pending) do
		table.insert(paths, path)
	end
	table.sort(paths)

	if #paths == 0 then
		print("No pending changes")
		return
	end

	-- Start iterating through paths
	local function process_next(index)
		if index > #paths then
			print("Finished reviewing pending changes")
			return
		end

		-- Open current path diff view
		local path = paths[index]
		local buf = M.open_pending_diff(path)

		-- Force to show diff (won't work without this)
		vim.cmd("redraw")

		-- List actions on cmdline
		print(
			string.format(
				"Reviewing %s (%d/%d): [a]pply, [d]iscard, [n]ext, [q]uit",
				path,
				index,
				#paths
			)
		)

		-- Get keycode to base action on
		local ok, char_code = pcall(vim.fn.getchar)
		if not ok then
			return
		end
		-- TODO: fix if misbehaves
		---@diagnostic disable-next-line: param-type-mismatch
		local char = vim.fn.nr2char(char_code)

		vim.cmd("normal! :")

		-- Delete the buffer to make room for second
		if vim.api.nvim_buf_is_valid(buf) then
			vim.api.nvim_buf_delete(buf, { force = true })
		end

		if char == "a" then
			-- Apply (write to disk)
			local final_content = utils.get_file_content(path, M.pending[path])
			utils.write_file(path, final_content)
			M.pending[path] = nil
			print("Applied changes to " .. path)
			process_next(index + 1)
		elseif char == "d" then
			-- Discard changes
			-- TODO: Host and client get out of sync here, force sync
			M.pending[path] = nil
			print("Discarded changes for " .. path)
			process_next(index + 1)
		elseif char == "n" then
			-- Skip change
			print("Skipped " .. path)
			process_next(index + 1)
		elseif char == "q" then
			-- Stop reviewing
			return
		else
			print("Invalid option. Press 'a', 'd', 'n', or 'q'")
			process_next(index)
		end
	end

	process_next(1)
end

-- Listen for buffer line changes
function M.attach_buf_listener(buf, on_change)
	-- Don't attach same buffer twice
	if M.attached[buf] then
		return
	end

	local path = utils.get_rel_path(buf)
	if not path then
		print("Buffer outside project root, not applying listener")
		return
	end

	-- Check for pending changes and apply them before attaching listener
	-- This brings the buffer up to date with the server
	if M.pending[path] then
		local changes = M.pending[path]
		for _, change in ipairs(changes) do
			M.apply_change(buf, change)
		end
		M.pending[path] = nil
		print("Applied pending changes for " .. path)
	end

	vim.api.nvim_buf_attach(buf, false, {
		on_lines = function(_, _, _, first, old_last, new_last)
			-- Prevent echoing back changes we just applied from the server
			if M.is_applying then
				return
			end

			local lines =
				vim.api.nvim_buf_get_lines(buf, first, new_last, false)
			on_change(path, {
				-- First line number where change started
				first = first,
				-- Last line number where change ended
				old_last = old_last,
				-- Content in between
				lines = lines,
			})
		end,
		on_detach = function()
			M.attached[buf] = nil
		end,
	})
	M.attached[buf] = true
end

return M
