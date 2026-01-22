local uv = vim.uv or vim.loop

local M = {}

-- Decodes json from a string
function M.decode_json(str)
	local ok, res = pcall(vim.json.decode, str)
	return ok and res or nil
end

-- Encodes lua table to json
function M.encode_json(ltable)
	local ok, res = pcall(vim.json.encode, ltable)
	return ok and res or nil
end

-- Get all files recursively and return list of relative paths
-- path/another_path/file.pl
-- Uses depth-first search
function M.get_files(root_path)
	root_path = root_path or "."
	local files = {}
	-- TODO: Add patterns to config
	local ignore_patterns =
		{ "%.git", "node_modules", "%.venv", "build", "%.env" }

	-- List of not looked directories
	local stack = { root_path }

	-- Returns true if file is in ignored patterns
	local function is_ignored(path)
		for _, pattern in ipairs(ignore_patterns) do
			if path:match(pattern) then
				return true
			end
		end
		return false
	end

	-- TODO: Add max depth
	while #stack > 0 do
		-- Pops directory out of the stack
		local current_dir = table.remove(stack)
		-- Open the popped directory
		local scanner = uv.fs_scandir(current_dir)

		-- Iterate the each directory
		if scanner then
			for name, type in
				-- Move to next
				function()
					return uv.fs_scandir_next(scanner)
				end
			do
				-- Clean up the path, no ./file.c
				local rel_path = current_dir == "." and name
					or (current_dir .. "/" .. name)

				-- If file is not on the naughty list check it
				if not is_ignored(rel_path) then
					-- If dir add it to stack (will be processed later)
					if type == "directory" then
						table.insert(stack, rel_path)
					-- If file just add it to final "files"
					elseif type == "file" then
						table.insert(files, rel_path)
					end
				end
			end
		end
	end

	return files
end

-- Reads a file, retuns nil if unable to open or non-exited
function M.read_file(path)
	-- Opens the file in read mode with 0644 permissions
	local fd = uv.fs_open(path, "r", tonumber("644", 8))
	if not fd then
		return nil
	end

	-- Get size for reading
	local stat = uv.fs_fstat(fd)
	if not stat then
		uv.fs_close(fd)
		return nil
	end

	-- Read and return contents
	local data = uv.fs_read(fd, stat.size, 0)
	uv.fs_close(fd)
	return data
end

-- Return relative path to CWD
function M.get_rel_path(bufnr)
	-- Get full path (/home/lentava_pomeranian/repos/hauva/src/main.c)
	local full_path = vim.api.nvim_buf_get_name(bufnr or 0)
	-- Return relative path to the CWD (src/main.c)
	return vim.fn.fnamemodify(full_path, ":.")
end

return M
