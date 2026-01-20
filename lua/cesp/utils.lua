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
	local ignore_patterns =
		{ "%.git", "node_modules", "%.venv", "build", "%.env" }

	local stack = { root_path }

	local function is_ignored(path)
		for _, pattern in ipairs(ignore_patterns) do
			if path:match(pattern) then
				return true
			end
		end
		return false
	end

	while #stack > 0 do
		local current_dir = table.remove(stack)
		local scanner = uv.fs_scandir(current_dir)

		if scanner then
			for name, type in
				function()
					return uv.fs_scandir_next(scanner)
				end
			do
				local rel_path = current_dir == "." and name
					or (current_dir .. "/" .. name)

				if not is_ignored(rel_path) then
					if type == "directory" then
						table.insert(stack, rel_path)
					elseif type == "file" or type == "link" then
						table.insert(files, rel_path)
					end
				end
			end
		end
	end

	return files
end

function M.read_file(path)
	local fd = uv.fs_open(path, "r", tonumber("644", 8))
	if not fd then
		return nil
	end

	local stat = uv.fs_fstat(fd)
	if not stat then
		uv.fs_close(fd)
		return nil
	end

	local data = uv.fs_read(fd, stat.size, 0)
	uv.fs_close(fd)
	return data
end

return M
