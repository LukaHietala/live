local browser = require("cesp.browser")
local utils = require("cesp.utils")

local M = {}

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

	-- Received request for filetree
	if payload.event == "request_files" then
		local file_list = utils.get_files(".")

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
		-- TODO: pending, current buffer. Just io for now
		local content = utils.read_file(payload.path)

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
		browser.open_remote_file(path, content)
		return
	end

	-- Event that contains client's cursor positions
	if payload.event == "cursor_move" then
		cursor.handle_cursor_move(payload)
		return
	end

	-- Signals that client's cursor has scampered
	if payload.event == "cursor_leave" then
		cursor.handle_cursor_leave(payload)
		return
	end

	print("Not implemented :( " .. payload.event)
end

return M
