local events = require("cesp.events")
local utils = require("cesp.utils")
local config = require("cesp.config").config

local M = {}

local CURSOR_GROUP =
	vim.api.nvim_create_augroup("RemoteCursor", { clear = true })
local CURSOR_NS = vim.api.nvim_create_namespace("remote_cursors")
local RANGE_OFFSET = 100000

-- Safely safely deletes extmark
local function safe_del_mark(buf, id)
	if vim.api.nvim_buf_is_valid(buf) then
		pcall(vim.api.nvim_buf_del_extmark, buf, CURSOR_NS, id)
	end
end

-- Clears all cursors
function M.clear_all_remote_cursors()
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		vim.api.nvim_buf_clear_namespace(buf, CURSOR_NS, 0, -1)
	end
end

function M.handle_cursor_leave(payload)
	if not payload.from_id then
		return
	end

	-- Extmarks are 0-indexed and nvim requires them to be positive
	local cursor_id = payload.from_id + 1
	local select_id = payload.from_id + RANGE_OFFSET

	-- Clear this user's cursor from all buffers
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		safe_del_mark(buf, cursor_id)
		safe_del_mark(buf, select_id)
	end
end

function M.start_cursor_tracker()
	vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "BufEnter" }, {
		group = CURSOR_GROUP,
		callback = function()
			-- Get current buf path
			local path = utils.get_rel_path(0)
			if not path or path == "" then
				return
			end

			-- Get current buf cursor_pos
			local cursor_pos = vim.api.nvim_win_get_cursor(0)
			local payload = {
				event = "cursor_move",
				-- Make 0- indexed
				position = { cursor_pos[1] - 1, cursor_pos[2] },
				path = path,
			}

			-- On visual mode add hightlight start_pos to cursor_move
			-- Highlight will be drawn between this start_pos (start) and cursor_pos (end)
			local mode = vim.api.nvim_get_mode().mode
			if mode:match("[vV]") then
				-- getpos returns [bufnum, lnum, col, off]
				local v_pos = vim.fn.getpos("v")
				payload.selection = {
					-- Make 0- indexed
					start_pos = { v_pos[2] - 1, v_pos[3] - 1 },
				}
			end

			events.send_event(payload)
		end,
	})

	-- This event is not stricly necessary but prevents so many headaches with
	-- lingering cursors
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = CURSOR_GROUP,
		callback = function()
			events.send_event({ event = "cursor_leave" })
		end,
	})
end

function M.handle_cursor_move(payload)
	if not payload.from_id or not payload.path then
		return
	end

	-- Extmarks are 0-indexed and nvim requires them to be positive
	local cursor_id = payload.from_id + 1
	local select_id = payload.from_id + RANGE_OFFSET

	-- Cursor coords
	local row = payload.position[1]
	local col = payload.position[2]
	local name = payload.name or "???"

	-- Find the specific buffer this cursor belongs to
	local target_buf = utils.find_buffer_by_rel_path(payload.path)

	-- Iterate all buffers to ensure we clear ghosts from previous files
	-- while updating the correct file
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(buf) then
			-- If this is not the target buffer, remove the cursor (client likely switched files)
			if buf ~= target_buf then
				safe_del_mark(buf, cursor_id)
				safe_del_mark(buf, select_id)
			else
				-- Draw regular cursor
				local cursor_opts = {
					id = cursor_id,
					hl_group = "TermCursor",
					virt_text = { { " " .. name, config.cursor.hl_group } },
					virt_text_pos = config.cursor.pos,
					end_row = row,
					end_col = col + 1,
					strict = false,
				}
				pcall(
					vim.api.nvim_buf_set_extmark,
					buf,
					CURSOR_NS,
					row,
					col,
					cursor_opts
				)

				-- Draw visual election (if exists)
				if payload.selection then
					local s_row = payload.selection.start_pos[1]
					local s_col = payload.selection.start_pos[2]

					-- Swap, start must be before end
					local r1, c1, r2, c2 = row, col, s_row, s_col
					if r1 > r2 or (r1 == r2 and c1 > c2) then
						r1, c1, r2, c2 = r2, c2, r1, c1
					end

					local sel_opts = {
						id = select_id,
						hl_group = "Visual",
						end_row = r2,
						end_col = c2 + 1,
						strict = false,
					}
					pcall(
						vim.api.nvim_buf_set_extmark,
						buf,
						CURSOR_NS,
						r1,
						c1,
						sel_opts
					)
				else
					-- If no selection make sure to clear any old selection
					safe_del_mark(buf, select_id)
				end
			end
		end
	end
end

return M
