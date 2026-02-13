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
function M.get_files()
	local root_path = vim.fs.normalize(M.get_project_root())
	local files = {}
	-- TODO: Add patterns to config
	local ignore_patterns =
		{ "%.git", "node_modules", "%.venv", "build", "%.env" }

	-- List of not looked directories
	local stack = { root_path }

	local function make_relative(full_path)
		local rel = full_path:sub(#root_path + 1)
		if rel:sub(1, 1) == "/" then
			rel = rel:sub(2)
		end
		return rel
	end

	-- Returns true if file is in ignored patterns
	local function is_ignored(path)
		for _, pattern in ipairs(ignore_patterns) do
			-- TODO?: Fix if too relaxed match
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
				local full_path = vim.fs.joinpath(current_dir, name)

				-- If file is not on the naughty list check it
				if not is_ignored(full_path) then
					-- If dir add it to stack (will be processed later)
					if type == "directory" then
						table.insert(stack, full_path)
					-- If file just add it to final "files"
					elseif type == "file" then
						table.insert(files, make_relative(full_path))
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

-- Write to file
function M.write_file(path, content)
	local abs_path = M.get_abs_path(path)
	local fd = assert(io.open(abs_path, "w"))
	fd:write(content)
	fd:close()
end

-- Get project root path, .git or cwd
function M.get_project_root()
	-- TODO: Move root markers to config
	-- TODO: Maybe in checkhealth say what this is using? cwd or root marker
	local root_markers = { ".git" }
	local root = vim.fs.root(0, root_markers)
	return root or vim.uv.cwd()
end

-- Robust check to ensure we don't return partial path matches
function M.get_rel_path(bufnr)
	-- Try to get full path
	local full_path = vim.api.nvim_buf_get_name(bufnr or 0)
	if full_path == "" then
		return nil
	end

	local root = M.get_project_root()
	-- Normalize and ensure trailing slashes
	local abs_path = vim.fs.normalize(vim.fn.fnamemodify(full_path, ":p"))
	local root_path = vim.fs.normalize(vim.fn.fnamemodify(root, ":p"))
	-- Little trick that prevents this trying to match partial
	-- file names /path/<dir_name_that_also_matches_filename_katti> ->
	-- /path/<dir_name_that_also_matches_filename>/
	if root_path:sub(-1) ~= "/" then
		root_path = root_path .. "/"
	end

	-- Remove root path from result (cleaan and relative path)
	if abs_path:sub(1, #root_path) == root_path then
		return abs_path:sub(#root_path + 1)
	end

	-- Do not expose paths outside root
	return nil
end

-- Gets absolute path from project relative path
-- USE THIS FOR CRITICAL THINGS!
function M.get_abs_path(path)
	return vim.fs.normalize(vim.fs.joinpath(M.get_project_root(), path))
end

-- Find a buffer by its relative path
function M.find_buffer_by_rel_path(rel_path)
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if
			vim.api.nvim_buf_is_valid(buf)
			and M.get_rel_path(buf) == rel_path
		then
			return buf
		end
	end
	return nil
end

function M.get_file_content(path, pending_changes)
	local abs_path = M.get_abs_path(path)

	local lines = {}
	local bufnr = M.find_buffer_by_rel_path(path)

	-- Get base content
	if bufnr and vim.api.nvim_buf_is_loaded(bufnr) then
		lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	else
		local content = M.read_file(abs_path)
		if content then
			lines = vim.split(content, "\n", { trimempty = false })
		end
	end

	--If no pending changes provided, return base content
	if not pending_changes or #pending_changes == 0 then
		return table.concat(lines, "\n")
	end

	-- Apply pending changes
	-- Using neovim's own buffers for this to be more safe and...
	-- BLAZINGLY FAST (optimized c)

	-- Create temp buf to apply changes to
	local temp_buf = vim.api.nvim_create_buf(false, true)
	-- Set base lines (disk)
	vim.api.nvim_buf_set_lines(temp_buf, 0, -1, false, lines)

	-- Merge pending changes (reverse to keep indexes right)
	for i = #pending_changes, 1, -1 do
		local change = pending_changes[i]
		vim.api.nvim_buf_set_lines(
			temp_buf,
			change.first,
			change.old_last,
			false,
			change.lines
		)
	end

	-- Get end result and cleanup
	local result_lines = vim.api.nvim_buf_get_lines(temp_buf, 0, -1, false)
	vim.api.nvim_buf_delete(temp_buf, { force = true })

	return table.concat(result_lines, "\n")
end

-- Returns buffer's SHA256 content hash
function M.get_buf_sha256(buf)
	if
		not vim.api.nvim_buf_is_valid(buf)
		and not vim.api.nvim_buf_is_loaded(buf)
	then
		return nil
	end

	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local content = table.concat(lines, "\n")

	return vim.fn.sha256(content)
end

return M
