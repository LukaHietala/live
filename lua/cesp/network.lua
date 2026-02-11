local uv = vim.uv or vim.loop
local cursor = require("cesp.cursor")
local events = require("cesp.events")
local config = require("cesp.config").config

local M = {}
M.handle = nil

-- Reads incoming stream
local function on_read()
	local chunks = {}

	return function(err, chunk)
		-- On error/disconnect clear cursors and close gracefully
		if err or not chunk then
			vim.schedule(cursor.clear_all_remote_cursors)
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
						events.handle_event(line)
					end)
				end
			end
		end
	end
end

function M.start_client(ip, is_host)
	if M.handle then
		if not M.handle:is_closing() then
			print("Already connected, try again") -- :katti:
			return
		else
			-- Something probably went wrong so just reset the handle
			M.handle = nil
		end
	end

	M.handle = uv.new_tcp()

	M.handle:connect(ip, config.port, function(err)
		if err then
			print(err)
			M.handle = nil
			return
		end

		-- Do the required handshake (required by host)
		events.send_event({
			event = "handshake",
			name = config.name,
			host = is_host,
		})

		-- TODO: add handshake response, so we know "this" client's id and other details

		vim.schedule(function()
			-- Attach cursor tracker
			cursor.start_cursor_tracker()

			-- Share buf on open
			vim.api.nvim_create_autocmd("BufReadPost", {
				callback = function(e)
					local buffer = require("cesp.buffer")
					buffer.attach_buf_listener(e.buf, function(path, changes)
						events.send_event({
							event = "update_content",
							path = path,
							changes = changes,
						})
					end)
				end,
			})
		end)

		-- Start reading
		M.handle:read_start(on_read())
	end)
end

-- Cleans up connections and cursors
function M.stop()
	if M.handle then
		events.send_event({ event = "cursor_leave" })

		if not M.handle:is_closing() then
			M.handle:close()
		end
		M.handle = nil
	end

	vim.schedule(function()
		cursor.clear_all_remote_cursors()
		-- Reset client state
		events.state.is_host = false
		events.state.client_id = nil
	end)

	print("Closed connection")
end

return M
