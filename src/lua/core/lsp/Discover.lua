--- Find a language server the machine already has.
--
-- Lunar does not download servers. A server is found, in this order:
--
--   1. the path the user set in Settings (it must exist, or that is the answer:
--      a wrong setting is reported, not silently skipped);
--   2. a copy shipped inside Lunar's own folder (`servers/<dir>/`), which is as
--      trusted as the rest of the install;
--   3. the system `PATH`.
--
-- The result always says where it looked, so the UI can tell the user plainly
-- that nothing was found and what would fix it.
--
-- @module core.lsp.Discover
local M = {}

local WINDOWS = package.config:sub(1, 1) == "\\"
local SEP = WINDOWS and "\\" or "/"

local function default_exists(path)
	local ok, lfs = pcall(require, "lfs")
	if ok then return lfs.attributes(path, "mode") == "file" end
	local file = io.open(path, "rb")
	if file then file:close() end
	return file ~= nil
end

local function join(dir, name, windows)
	if dir:sub(-1) == "/" or dir:sub(-1) == "\\" then return dir .. name end
	if windows == nil then return dir .. SEP .. name end
	return dir .. (windows and "\\" or "/") .. name
end

-- The file names one executable name can have on this platform.
local function candidates(name, windows, pathext)
	if not windows then return { name } end
	local given = name:lower():match("%.(%w+)$")
	if given == "exe" or given == "cmd" or given == "bat" or given == "com" then return { name } end
	local out = {}
	for ext in (pathext or ".COM;.EXE;.BAT;.CMD"):gmatch("[^;]+") do
		out[#out + 1] = name .. ext:lower()
	end
	return out
end

--- Search a `PATH`-style list for the first of `names`.
-- @tparam {string,...} names executable names, without extension
-- @tparam[opt] table opts `path`, `pathext`, `windows`, `exists` (for tests)
-- @treturn string|nil the full path
function M.onPath(names, opts)
	opts = opts or {}
	local windows = opts.windows
	if windows == nil then windows = WINDOWS end
	local exists = opts.exists or default_exists
	local path = opts.path or os.getenv("PATH") or ""
	local pathext = opts.pathext or (windows and os.getenv("PATHEXT")) or nil
	local list_sep = windows and ";" or ":"
	for dir in path:gmatch("[^" .. list_sep .. "]+") do
		dir = dir:gsub('^"(.*)"$', "%1")
		if dir ~= "" then
			for _, name in ipairs(names) do
				for _, file in ipairs(candidates(name, windows, pathext)) do
					local full = join(dir, file, windows)
					if exists(full) then return full end
				end
			end
		end
	end
	return nil
end

--- Find a server.
--
-- @tparam table spec
-- @tparam string spec.label what to call the server, e.g. `"clangd"`
-- @tparam {string,...} spec.names executable names to look for
-- @tparam[opt] string spec.configured the path from Settings, if the user set one
-- @tparam[opt] {string,...} spec.bundled files to try under Lunar's own folder,
--   relative to `spec.app_dir`
-- @tparam[opt] string spec.app_dir Lunar's install folder
-- @tparam[opt] string spec.install how to get the server, appended to the
--   not-found message
-- @tparam[opt] table opts as for `onPath`
-- @treturn[1] string the executable
-- @treturn[1] string where it came from: `"settings"`, `"bundled"` or `"path"`
-- @treturn[2] nil
-- @treturn[2] string a sentence the UI can show as it is
function M.find(spec, opts)
	opts = opts or {}
	local exists = opts.exists or default_exists
	local configured = spec.configured
	if type(configured) == "string" and configured:match("%S") then
		configured = configured:gsub("^%s+", ""):gsub("%s+$", ""):gsub('^"(.*)"$', "%1")
		if exists(configured) then return configured, "settings" end
		return nil, string.format("%s is set to %s in Settings, but that file does not exist.",
			spec.label, configured)
	end
	if spec.app_dir then
		for _, relative in ipairs(spec.bundled or {}) do
			if WINDOWS then relative = relative:gsub("/", "\\") end
			local full = join(spec.app_dir, relative)
			if exists(full) then return full, "bundled" end
		end
	end
	local found = M.onPath(spec.names or {}, opts)
	if found then return found, "path" end
	local message = string.format("%s was not found on this computer.", spec.label)
	if spec.install then message = message .. " " .. spec.install end
	return nil, message
end

return M
