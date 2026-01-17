local uv = vim.uv or vim.loop

local M = {}

-- Current libuv uv_tcp_t handle
M.handle = nil

local function decode_json(str)
	local ok, res = pcall(vim.json.decode, str)
	return ok and res or nil
end

local function encode_json(json)
	local ok, res = pcall(vim.json.encode, json)
	return ok and res or nil
end

local function send_event(event_table)
	if not M.handle or M.handle:is_closing() then
		print("Unable to send the event")
		return
	end

	local event_str = encode_json(event_table)
	if event_str then
		M.handle:write(event_str .. "\n")
	end
end

local function start_client()
	-- Create scratch buffer
	local buf = vim.api.nvim_create_buf(false, true)
	vim.cmd("vsplit | b" .. buf)

	M.handle = uv.new_tcp()
	local chunks = {}

	M.handle:connect("127.0.0.1", 8080, function(err)
		if err then
			return print(err)
		end

		-- Handshake
		local handshake_event = {
			event = "handshake",
			name = "lentava_pomeranian",
		}
		send_event(handshake_event)

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

				-- Update scratch buf
				if #lines > 0 then
					vim.schedule(function()
						if vim.api.nvim_buf_is_valid(buf) then
							vim.api.nvim_buf_set_lines(
								buf,
								-1,
								-1,
								false,
								lines
							)
						end
					end)
				end
			end
		end)
	end)
end

start_client()
