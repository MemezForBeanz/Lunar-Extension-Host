--- A private module cache and `require` for one extension.
--
-- Folder extensions ship their own modules (`classes.X`, `ui.X`, `libs.X`,
-- native `.dll`/`.so` modules in the folder or `native/`). If those went through
-- the global `require`, two extensions that both ship `classes.Util` would share
-- whichever loaded first, and a reload would keep running the old code from
-- `package.loaded`. Instead each extension gets:
--
--   * its own `require`, which resolves names inside the extension's folder
--     first, at any time (also from callbacks long after loading), and falls back
--     to the host's `require` for everything else (`iup`, `cjson`, `core.*`, ...);
--   * its own cache of those modules, dropped with the extension on unload.
--
-- The extension's chunks run in an environment that reads and writes globals
-- straight through to `_G`, so global behaviour is unchanged; only `require` (and
-- `package.loaded` lookups through it) are per extension.
--
-- As a safety net, `track_global(fn)` records `package.loaded` keys that appear
-- while the extension loads; `unload()` removes the ones whose files live inside
-- the extension's folder (an extension that called the global `require` itself).
--
-- @module core.lib.ExtensionModules

local platform = require("core.platform")

local M = {}
M.__index = M

local sep, lib_ext = platform.sep, platform.lib_ext

--- Create the module scope for an extension rooted at `dir`.
-- @tparam string dir The extension's folder.
-- @treturn table scope with `require`, `env`, `loadfile`, `track_global`, `unload`
function M.new(dir)
	local self = setmetatable({}, M)
	self.dir = dir
	self.path = table.concat({
		dir .. sep .. "?.lua",
		dir .. sep .. "?" .. sep .. "init.lua",
	}, ";")
	self.cpath = table.concat({
		dir .. sep .. "?." .. lib_ext,
		dir .. sep .. "native" .. sep .. "?." .. lib_ext,
	}, ";")
	self.loaded = {}          -- name -> module value, this extension only
	self.global_keys = {}     -- package.loaded keys this extension added (see track_global)
	self.env = setmetatable({}, { __index = _G, __newindex = _G })
	rawset(self.env, "require", function(name) return self:require(name) end)
	return self
end

-- The first file `template` (a `;`-separated list of `?` patterns) yields for
-- `name`, like package.searchpath.
local function search(name, template)
	local file = name:gsub("%.", sep)
	for pattern in template:gmatch("[^;]+") do
		local candidate = pattern:gsub("%?", (file:gsub("%%", "%%%%")))
		local f = io.open(candidate, "rb")
		if f then f:close(); return candidate end
	end
	return nil
end

--- Compile a Lua file of this extension so that it runs in the extension's environment.
-- @tparam string file
-- @treturn function|nil chunk
-- @treturn string|nil error
function M:loadfile(file)
	local chunk, err = loadfile(file)
	if not chunk then return nil, err end
	setfenv(chunk, self.env)
	return chunk
end

--- `require` as seen by the extension: its own folder first, then the host's.
-- @tparam string name
-- @return the module value
function M:require(name)
	local cached = self.loaded[name]
	if cached ~= nil then return cached end

	local file = search(name, self.path)
	if file then
		local chunk, err = self:loadfile(file)
		if not chunk then error("error loading module '" .. name .. "' from " .. file .. ":\n\t" .. err, 2) end
		-- Mark it as loading so a require cycle gets `true` instead of recursing forever.
		self.loaded[name] = true
		local ok, value = pcall(chunk, name, file)
		if not ok then
			self.loaded[name] = nil
			error(value, 0)
		end
		if value == nil then value = true end
		self.loaded[name] = value
		return value
	end

	local native = search(name, self.cpath)
	if native then
		-- Lua 5.1 rule: "a.b-c" opens luaopen_a_b; the part after '-' is a version tag.
		local symbol = "luaopen_" .. name:gsub("^[^-]*-", ""):gsub("%.", "_")
		local open, err = package.loadlib(native, symbol)
		if not open then error("error loading module '" .. name .. "' from " .. native .. ":\n\t" .. tostring(err), 2) end
		local value = open(name)
		if value == nil then value = true end
		self.loaded[name] = value
		return value
	end

	return require(name)
end

--- Run `fn(...)` and record the `package.loaded` keys that appear meanwhile.
-- @tparam function fn
-- @return whatever `fn` returns (errors propagate)
function M:track_global(fn, ...)
	local before = {}
	for k in pairs(package.loaded) do before[k] = true end
	local results = { pcall(fn, ...) }
	for k in pairs(package.loaded) do
		if not before[k] then self.global_keys[#self.global_keys + 1] = k end
	end
	if not results[1] then error(results[2], 0) end
	return unpack(results, 2, table.maxn(results))
end

--- Drop this extension's modules: its private cache, and any `package.loaded`
-- entry it added whose file lives inside its folder. Shared host modules that it
-- happened to load first (`copas`, `date`, ...) stay loaded.
-- @treturn table names removed from `package.loaded`
function M:unload()
	local removed = {}
	for _, key in ipairs(self.global_keys) do
		if type(key) == "string" and (search(key, self.path) or search(key, self.cpath)) then
			package.loaded[key] = nil
			removed[#removed + 1] = key
		end
	end
	self.global_keys = {}
	self.loaded = {}
	return removed
end

return M
