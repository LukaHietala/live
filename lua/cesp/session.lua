local uv = vim.uv or vim.loop
local browser = require("cesp.browser")
local utils = require("cesp.utils")

local M = {}

M.config = {
	port = 8080,
}
-- Current libuv uv_tcp_t handle
M.handle = nil

-- Open remote content in buffer
local function open_remote_file(path, content)
	vim.schedule(function()
		local target_name = path .. " (remote)"
		local found_buf = nil

		-- Search for currently open buffers
		for _, buf in ipairs(vim.api.nvim_list_bufs()) do
			local name = vim.api.nvim_buf_get_name(buf)
			if
				-- Compare only the last portion to be more reliable
				name:sub(-#target_name) == target_name
				and vim.api.nvim_buf_is_valid(buf)
			then
				found_buf = buf
				break
			end
		end

		local buf = found_buf

		--If not found, create and configure a new buffer
		if not buf then
			buf = vim.api.nvim_create_buf(true, true)
			pcall(vim.api.nvim_buf_set_name, buf, target_name)

			-- "nofile" to prevent standard write behaviour
			vim.bo[buf].buftype = "nofile"
			vim.bo[buf].swapfile = false
			-- Don't unload when abandoned
			vim.bo[buf].bufhidden = "hide"

			-- Try to detect filetype for syntax. LSP don't work because they require more context
			local ft = vim.filetype.match({ filename = path })
			if ft then
				vim.bo[buf].filetype = ft
			end
		end

		-- Update the content
		local lines = vim.split(content, "\n", { plain = true })
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

		vim.api.nvim_set_current_buf(buf)
	end)
end

local function send_event(event_table)
	if not M.handle or M.handle:is_closing() then
		print("Unable to send the event")
		return
	end

	local event_str = utils.encode_json(event_table)
	if event_str then
		M.handle:write(event_str .. "\n")
	end
end

local function handle_event(json_str)
	local payload = utils.decode_json(json_str)
	if not payload or not payload.event then
		return
	end

	if payload.event == "request_files" then
		local file_list = utils.get_files(".")

		send_event({
			event = "response_files",
			files = file_list,
			request_id = payload.request_id,
		})
		return
	end

	if payload.event == "response_files" then
		vim.schedule(function()
			if payload.files and #payload.files > 0 then
				browser.open_file_browser(payload.files, function(path)
					send_event({
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

	if payload.event == "request_file" then
		-- TODO: pending, current buffer. Just io for now
		local content = utils.read_file(payload.path)

		if not content then
			return
		end

		send_event({
			event = "response_file",
			path = payload.path,
			content = content,
			request_id = payload.request_id,
		})
	end

	if payload.event == "response_file" then
		local content = payload.content
		local path = payload.path

		if not content then
			print("No content from" .. path)
		end

		open_remote_file(path, content)
		return
	end

	print("Not implemented " .. payload.event)
end

function M.list_remote_files()
	send_event({
		event = "request_files",
	})
end

function M.start_client(ip)
	M.handle = uv.new_tcp()
	local chunks = {}

	M.handle:connect(ip, 8080, function(err)
		if err then
			return print(err)
		end

		send_event({
			event = "handshake",
			name = "lentava_pomeranian",
		})

		M.handle:read_start(function(err, chunk)
			if err or not chunk then
				return M.handle:close()
			end

			table.insert(chunks, chunk)

			-- Only process if we see a newline (the end of at least one message)
			if chunk:find("\n") then
				local raw_data = table.concat(chunks)
				chunks = {}

				-- Split data into lines
				local lines = vim.split(raw_data, "\n", { plain = true })

				-- Handle Fragmentation
				local leftover = table.remove(lines)
				if leftover ~= "" then
					table.insert(chunks, leftover)
				end

				-- Handle events
				for _, line in ipairs(lines) do
					if line ~= "" then
						vim.schedule(function()
							handle_event(line)
						end)
					end
				end
			end
		end)
	end)
end

function M.stop()
	if M.handle then
		M.handle:close()
	end
end

return M
