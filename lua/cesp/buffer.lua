local utils = require("cesp.utils")

local M = {}

-- List of buffer that have nvim_buf listener
M.attached = {}
-- True if buffer changes are happening
M.is_applying = false
-- List of pending changes from other clients on non-open buffers
M.pending = {}

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

	if ok then
		print("Applied pending changes automatically")
	else
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

-- Listen for buffer line changes
function M.attach_buf_listener(buf, on_change)
	-- Don't attach same buffer twice
	if M.attached[buf] then
		return
	end

	local path = utils.get_rel_path(buf)

	-- Check for pending changes and apply them before attaching listener
	-- This brings the buffer up to date with the server
	if M.pending[path] then
		local changes = M.pending[path]
		for _, change in ipairs(changes) do
			M.apply_change(buf, change)
		end
		M.pending[path] = nil
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
