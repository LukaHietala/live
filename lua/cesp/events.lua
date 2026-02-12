local browser = require("cesp.browser")
local buffer = require("cesp.buffer")
local utils = require("cesp.utils")

local M = {}
-- Client's state
M.state = {}
-- Are writes from client allowed (scary)
M.allow_remote_write = false

-- Sends event to the server
function M.send_event(event_table)
	local network = require("cesp.network")

	-- Don't try to write to non-existing handle/pipe
	if not network.handle or network.handle:is_closing() then
		print("Unable to send the event, maybe join?")
		return
	end

	local event_str = utils.encode_json(event_table)
	if event_str then
		-- Server uses \n as delimeter
		network.handle:write(event_str .. "\n")
	end
end

-- Handles every event received from server
function M.handle_event(json_str)
	local cursor = require("cesp.cursor")
	-- Get event details
	local payload = utils.decode_json(json_str)
	if not payload or not payload.event then
		return
	end

	-- After handshake server sends client metadata (mirrored on server)
	if payload.event == "handshake_response" then
		if
			payload.id == nil
			or payload.name == nil
			or payload.is_host == nil
		then
			return
		end

		M.state = {
			id = payload.id,
			name = payload.name,
			is_host = payload.is_host,
		}

		print("Joined as " .. M.state.name)
		return
	end

	-- If new host is assigned update state if necessary
	if payload.event == "new_host" then
		if payload.host_id == nil then
			return
		end

		-- If new host is self update state
		-- TODO: left message hides these messages, FIX
		if payload.host_id == M.state.id then
			print("You're the new host!")
			M.state.is_host = true
		else
			print(payload.name .. " is the new host!")
		end

		return
	end

	-- Received request for filetree
	if payload.event == "request_files" then
		local file_list = utils.get_files()

		M.send_event({
			event = "response_files",
			files = file_list,
			request_id = payload.request_id,
		})
		return
	end

	-- Received response with filetree
	if payload.event == "response_files" then
		vim.schedule(function()
			if payload.files and #payload.files > 0 then
				-- If files in response open explorer with them
				browser.open_file_browser(payload.files, function(path)
					-- On select request for selected file
					M.send_event({
						event = "request_file",
						path = path,
					})
				end)
			else
				print("No files received")
			end
		end)
		return
	end

	-- Received request for spesific file contents
	if payload.event == "request_file" then
		-- Get content from open buffer, if no open buffer then pending, and if no
		-- pending then disk
		local buffer_util = require("cesp.buffer")
		local content = utils.get_file_content(
			payload.path,
			buffer_util.pending[payload.path]
		)

		-- Don't send an empty file
		if not content then
			return
		end

		M.send_event({
			event = "response_file",
			path = payload.path,
			content = content,
			request_id = payload.request_id,
		})
		return
	end

	-- Received file response with file content
	if payload.event == "response_file" then
		local content = payload.content
		local path = payload.path

		-- Should not be possible, but never can be too safe :D
		if not content then
			print("No content from " .. path)
		end

		-- Opens an empty buffer that mimics real file buffer
		browser.open_remote_file(path, content, function(buf)
			-- Attach listeners to it
			buffer.attach_buf_listener(buf, function(p, c)
				M.send_event({
					event = "update_content",
					path = p,
					changes = c,
				})
			end)

			vim.api.nvim_create_autocmd("BufWriteCmd", {
				buffer = buf,
				callback = function()
					M.send_event({
						event = "remote_write",
						path = path,
						-- Host applies it own content, that miiight be synced currectly
						-- Clients can't be trusted >:(
					})
				end,
			})
		end)
		return
	end

	if payload.event == "update_content" then
		local path = payload.path
		local changes = payload.changes

		if not path or not changes then
			return
		end

		vim.schedule(function()
			local bufnr = utils.find_buffer_by_rel_path(path)

			-- Default to false if not found
			local is_visible = false
			local is_loaded = false

			if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
				is_loaded = vim.api.nvim_buf_is_loaded(bufnr)
				-- Check if any window is currently displaying this buffer
				local wins = vim.fn.win_findbuf(bufnr)
				is_visible = (wins and #wins > 0)
			end

			if is_visible then
				-- If buffer is on screen, apply live
				buffer.apply_change(bufnr, changes)
			elseif M.state.is_host then
				-- If buffer is hidden/not open on host apply pending
				buffer.add_pending(path, changes)
				-- Little hacky, but if host goes back to "hidden"
				-- buffer it will be out of sync if pending changes were not
				-- applied
				if is_loaded then
					buffer.apply_change(bufnr, changes)
				end
			elseif is_loaded then
				-- Keep every client buffer on sync
				buffer.apply_change(bufnr, changes)
			end
		end)
		return
	end

	-- Event that contains client's cursor positions
	if payload.event == "cursor_move" then
		vim.schedule(function()
			cursor.handle_cursor_move(payload)
		end)
		return
	end

	-- Signals that client's cursor has scampered
	if payload.event == "cursor_leave" then
		vim.schedule(function()
			cursor.handle_cursor_leave(payload)
		end)
		return
	end

	-- User joined event
	if payload.event == "user_joined" then
		if not payload.name then
			return
		end

		print(payload.name .. " joined!")
		return
	end

	-- User left id
	if payload.event == "user_left" then
		if not payload.name then
			return
		end

		print(payload.name .. " left :(")
		return
	end

	-- User sent request to write file
	if payload.event == "remote_write" then
		if not M.state.is_host then
			return
		end

		local path = payload.path
		local requestor_name = payload.name or "???"

		if not M.allow_remote_write then
			return
		end

		-- Get content from host's own buffer
		-- No trusting clients here
		local bufnr = utils.find_buffer_by_rel_path(path)
		local buffer_util = require("cesp.buffer")

		-- This feature is really dangereous and clunky, so it might get removed
		-- File might get messed up if host buffer gets out of sync or something else
		-- weird happens

		-- If buffer is open/valid/loaded :kisumirri:
		if
			bufnr
			and vim.api.nvim_buf_is_valid(bufnr)
			and vim.api.nvim_buf_is_loaded(bufnr)
		then
			vim.api.nvim_buf_call(bufnr, function()
				-- Maybe noautocmd later?
				vim.cmd("write")
			end)

			-- Clear pending as they are now committed via the write
			buffer_util.pending[path] = nil
		else
			-- Buffer is not open
			local content =
				utils.get_file_content(path, buffer_util.pending[path])

			if content then
				-- Standard write
				utils.write_file(path, content)
				buffer_util.pending[path] = nil

				print(requestor_name .. " wrote to " .. path)
			else
				print("Failed to save " .. path .. " (no content?)")
			end
		end

		return
	end

	if payload.event == "error" then
		if not payload.message then
			return
		end

		print(payload.message)
		return
	end

	print("Not implemented :( " .. payload.event)
end

return M
