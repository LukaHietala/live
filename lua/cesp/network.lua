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
			vim.schedule(clear_all_remote_cursors)
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

function M.start_client(ip)
	M.handle = uv.new_tcp()
	local chunks = {}

	M.handle:connect(ip, config.port, function(err)
		if err then
			print(err)
			return
		end

		-- Do the required handshake (required by host)
		events.send_event({
			event = "handshake",
			name = config.name,
		})

		-- TODO: add handshake response, so we know "this" client's id and other details

		-- Attach cursor tracker
		vim.schedule(cursor.start_cursor_tracker)
		-- Start reading
		M.handle:read_start(on_read())
	end)
end

-- Cleans up connections and cursors
function M.stop()
	if M.handle then
		events.send_event({ event = "cursor_leave" })
		M.handle:close()
		M.handle = nil
	end
	cursor.clear_all_remote_cursors()
end

return M
