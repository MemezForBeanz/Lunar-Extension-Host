--- Shared directory traversal primitives for plugins and the host.
-- The packaged host supplies `logscan.list_dir`, which returns entry type
-- metadata in one native enumeration; development runtimes transparently
-- fall back to LuaFileSystem (`lfs`).
--
-- The walk helpers are coroutine-aware: when running inside a coroutine
-- the built-in checkpoint timer yields control periodically so that
-- long scans do not starve the UI event loop.
-- @module core.lib.filescan

local lfs = require("lfs")
local platform = require("core.platform")

local filescan = {}

local ok_native, native = pcall(require, "logscan")
if not ok_native or type(native) ~= "table" then native = nil end

local SEP = platform.sep

--- Return the current time in milliseconds (monotonic wall clock).
-- @treturn number current time in milliseconds.
local function now_ms()
	return platform.clock.now() * 1000
end
filescan.now_ms = now_ms

--- List immediate children of a directory.
-- Uses the native `logscan.list_dir` when available; otherwise falls back
-- to LuaFileSystem. Returns an empty table when the path does not exist or
-- cannot be read. The `.` and `..` entries are always excluded.
-- @tparam string path absolute directory path.
-- @treturn table array of `{ name: string, dir: boolean }` entry records.
function filescan.listDir(path)
	if native and type(native.list_dir) == "function" then
		local ok, entries = pcall(native.list_dir, path)
		if ok and type(entries) == "table" then return entries end
	end

	local entries = {}
	local ok, iter, state = pcall(lfs.dir, path)
	if not ok or not iter then return entries end
	for name in iter, state do
		if name ~= "." and name ~= ".." then
			entries[#entries + 1] = {
				name = name,
				dir = lfs.attributes(path .. SEP .. name, "mode") == "directory",
			}
		end
	end
	return entries
end

--- Create a cooperative yield checkpoint for use inside a coroutine.
-- Returns a no-op function when the current context is not yieldable
-- (e.g. the main thread), so callers never need to check
-- `coroutine.isyieldable` themselves.
--
-- Each call to the returned function increments an operation counter; when
-- the counter reaches `max_ops_per_step` or the wall-clock budget expires
-- the coroutine yields and the counters reset.
-- @tparam[opt] table opts options table.
-- @tparam[opt=8] number opts.budget_ms wall-clock milliseconds allowed per step.
-- @tparam[opt=256] number opts.max_ops_per_step maximum operation ticks between yield checks.
-- @treturn function a `checkpoint()` closure to call inside a traversal loop.
function filescan.newCheckpoint(opts)
	local yieldable
	if type(coroutine.isyieldable) == "function" then
		yieldable = coroutine.isyieldable()
	else
		local running, is_main = coroutine.running()
		yieldable = running ~= nil and not is_main
	end
	if not yieldable then return function() end end
	opts = opts or {}
	local budget_ms = tonumber(opts.budget_ms) or 8
	local max_ops = tonumber(opts.max_ops_per_step) or 256
	local deadline, ops = now_ms() + budget_ms, 0
	return function()
		ops = ops + 1
		if ops >= max_ops or now_ms() >= deadline then
			coroutine.yield()
			deadline, ops = now_ms() + budget_ms, 0
		end
	end
end

--- Recursively collect files under a root directory.
-- The traversal is depth-first. When running in a coroutine the built-in
-- checkpoint yields periodically so long scans do not starve the UI.
-- @tparam string root absolute path to the directory to walk.
-- @tparam[opt] table opts options table.
-- @tparam[opt] function opts.accept_file `function(full_path, name, depth) -> boolean`; include only files for which it returns truthy.
-- @tparam[opt] function opts.should_descend `function(full_path, name, depth) -> boolean`; descend only into directories for which it returns truthy.
-- @tparam[opt] number opts.max_depth maximum directory depth (0 = root entries only).
-- @tparam[opt] number opts.max_files stop after collecting this many files.
-- @tparam[opt] number opts.budget_ms coroutine budget per step (forwarded to `newCheckpoint`).
-- @tparam[opt] number opts.max_ops_per_step ops-per-step limit (forwarded to `newCheckpoint`).
-- @tparam[opt] function opts.checkpoint pre-built checkpoint function; overrides the budget/ops options.
-- @treturn table array of absolute file paths (strings).
function filescan.walk(root, opts)
	opts = opts or {}
	local checkpoint = opts.checkpoint or filescan.newCheckpoint(opts)
	local max_depth = tonumber(opts.max_depth) or math.huge
	local max_files = tonumber(opts.max_files) or math.huge
	local files = {}

	local function visit(path, depth)
		if depth > max_depth or #files >= max_files then return end
		for _, entry in ipairs(filescan.listDir(path)) do
			local full = path .. SEP .. entry.name
			if entry.dir then
				if not opts.should_descend or opts.should_descend(full, entry.name, depth) then
					visit(full, depth + 1)
				end
			elseif not opts.accept_file or opts.accept_file(full, entry.name, depth) then
				files[#files + 1] = full
			end
			checkpoint()
			if #files >= max_files then return end
		end
	end

	visit(root, 0)
	return files
end

return filescan
