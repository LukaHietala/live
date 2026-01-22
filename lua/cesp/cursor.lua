local events = require("cesp.events")
local utils = require("cesp.utils")
local config = require("cesp.config").config

local M = {}

local cursor_au = vim.api.nvim_create_augroup("RemoteCursor", {
	clear = true,
})
local cursor_ns = vim.api.nvim_create_namespace("remote_cursors")

-- Goes trough every valid buffer and clears it's cursor namespace
function M.clear_all_remote_cursors()
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(buf) then
			vim.api.nvim_buf_clear_namespace(buf, cursor_ns, 0, -1)
		end
	end
end

-- On "cursor_leave" event delete cursor based on "from_id"
-- Cursor extmarks are marked with client's id
function M.handle_cursor_leave(payload)
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(buf) then
			pcall(vim.api.nvim_buf_del_extmark, buf, cursor_ns, payload.from_id)
		end
	end
end

-- Create autocmds for cursor tracking
function M.start_cursor_tracker()
	vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "BufEnter" }, {
		group = cursor_au,
		callback = function()
			local path = utils.get_rel_path(0)
			-- Only send if we are in a valid file buffer
			if path and path ~= "" then
				events.send_event({
					event = "cursor_move",
					position = vim.api.nvim_win_get_cursor(0),
					path = path,
				})
			end
		end,
	})

	-- On leave signal to other clients to delete this cursor
	vim.api.nvim_create_autocmd({ "VimLeavePre" }, {
		group = cursor_au,
		callback = function()
			events.send_event({
				event = "cursor_leave",
			})
		end,
	})
end

-- Handles "cursor_move" event
function M.handle_cursor_move(payload)
	-- Make sure the "from_id" is there, mark ids are based on those
	if not payload.from_id then
		return
	end

	-- ALWAYS clear this specific user's cursor from all buffers first
	-- This prevents the "ghost" cursor in the previous file
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(buf) then
			pcall(vim.api.nvim_buf_del_extmark, buf, cursor_ns, payload.from_id)
		end
	end

	local row = payload.position[1] - 1
	local col = payload.position[2]
	local name = payload.name or "???"

	-- Try to find the buffer they are currently in
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(buf) then
			local buf_name = vim.api.nvim_buf_get_name(buf)
			-- Check if this buffer matches the path sent by the client
			if buf_name:find(payload.path, 1, true) then
				pcall(vim.api.nvim_buf_set_extmark, buf, cursor_ns, row, col, {
					id = payload.from_id,
					end_col = col + 1,
					hl_group = "TermCursor",
					virt_text = { { " " .. name, config.cursor.hl_group } },
					virt_text_pos = config.cursor.pos,
					strict = false,
				})
				break
			end
		end
	end
end

return M
