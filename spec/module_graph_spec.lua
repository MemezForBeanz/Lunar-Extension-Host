-- spec/module_graph_spec.lua — every require() resolves to something that exists.
--
-- Commit a9ad92f removed the Lua-side `Gradient*` widget family when gradients and
-- rounded corners moved into the IUP fork. Three `require` calls for those deleted
-- modules survived it, in three different files, and each one only announced itself
-- at runtime:
--
--   * `core.ui.GradientDropButton` in ThemeManager  -> host would not start
--   * `core.ui.GradientScrollbar`  in SettingsView  -> host would not start
--   * `core.ui.GradientButton`     in buildqueue    -> that plugin failed to load
--
-- A missing require is invisible to luacheck (it does not resolve module names) and
-- invisible to the rest of the suite (which requires the modules it tests and no
-- others). It shows up when a user opens the app, or worse, opens one particular
-- panel. This walks the whole tree instead.

local lfs = require("lfs")

-- Provided by the C host, the vendored rocks, or LuaJIT itself, so they never have
-- a .lua file in this repository.
local EXTERNAL = {
	middleclass = true, lfs = true, cjson = true, iup = true, subprocess = true, process = true,
	socket = true, ltn12 = true, mime = true, ssl = true,
	copas = true, coxpcall = true, binaryheap = true, timerwheel = true,
	argparse = true, tableshape = true, serpent = true, date = true,
	logging = true, ffi = true, bit = true, jit = true, appimages = true,
	themeapply = true, svgicon = true, iupraw = true, winredraw = true,
	logscan = true, compositor = true,
}

-- Resolved at runtime from a location CMake populates, not from the source tree:
-- the CLI harness is copied next to LunarCLI.exe along with scanner.lua
-- (see the POST_BUILD step in CMakeLists.txt).
local BUILD_COPIED = {
	["src/lua/core/test_backend.lua"] = { scanner = true },
}

local function is_dir(path)
	local a = lfs.attributes(path)
	return a and a.mode == "directory"
end

local function walk(dir, out, skip)
	if not is_dir(dir) then return out end
	for entry in lfs.dir(dir) do
		if entry ~= "." and entry ~= ".." and not (skip and skip[entry]) then
			local path = dir .. "/" .. entry
			if is_dir(path) then
				walk(path, out, skip)
			elseif entry:match("%.lua$") then
				out[#out + 1] = path
			end
		end
	end
	return out
end

local function read(path)
	local f = assert(io.open(path, "r"), "cannot read " .. path)
	local text = f:read("*a")
	f:close()
	return text
end

local function host_module_exists(mod)
	return lfs.attributes("src/lua/" .. mod:gsub("%.", "/") .. ".lua") ~= nil
end

-- A plugin may also require modules shipped inside its own folder; the extension
-- loader puts that folder on package.path while the plugin loads (see
-- core.classes.ExtensionManager).
local function plugin_module_exists(plugin_dir, mod)
	local rel = mod:gsub("%.", "/")
	return lfs.attributes(plugin_dir .. "/" .. rel .. ".lua") ~= nil
		or lfs.attributes(plugin_dir .. "/" .. rel .. "/init.lua") ~= nil
end

describe("module graph", function()
	it("has no require() pointing at a module that does not exist", function()
		local files = walk("src/lua", {})
		-- cli/ and native/ hold C# and C sources, not Lua modules.
		walk("plugins", files, { cli = true, native = true })

		assert.is_true(#files > 40, "scanned only " .. #files .. " files; wrong directory?")

		local missing = {}
		for _, path in ipairs(files) do
			local plugin_dir = path:match("^(plugins/[^/]+)/")
			local allowed = BUILD_COPIED[path] or {}

			for mod in read(path):gmatch('require%s*%(%s*"([%w_%.]+)"%s*%)') do
				local root = mod:match("^[^.]+")
				local ok = EXTERNAL[root] or allowed[mod]
					or host_module_exists(mod)
					or (plugin_dir and plugin_module_exists(plugin_dir, mod))
				if not ok then
					missing[#missing + 1] = path .. " requires " .. mod
				end
			end
		end

		assert.are.same({}, missing)
	end)

	it("has no plugin entry point that cannot satisfy the extension contract", function()
		-- `ExtensionManager:_discover` treats EVERY *.lua directly in plugins/ as a
		-- single-file extension, and every plugins/<name>/init.lua as a folder one.
		-- An empty file passes loadfile happily, executes to nothing, and only fails
		-- at the "must return a table with register(ctx)" check -- surfacing as a
		-- plugin error dialog on every launch.
		--
		-- That is not hypothetical: a zero-byte plugins/hello.lua was committed
		-- alongside the real example in exampleplugins/, and errored at every start.
		--
		-- This is a shallow check by design: executing a plugin needs the live IUP
		-- toolkit and the host context. It catches the empty and the obviously
		-- contract-less, which is what has actually gone wrong.
		local entries = {}
		for entry in lfs.dir("plugins") do
			if entry:match("%.lua$") then
				entries[#entries + 1] = "plugins/" .. entry
			elseif entry ~= "." and entry ~= ".." and is_dir("plugins/" .. entry) then
				local init = "plugins/" .. entry .. "/init.lua"
				if lfs.attributes(init) then entries[#entries + 1] = init end
			end
		end
		-- exampleplugins/ is not scanned by the host, but it is what people copy.
		for entry in lfs.dir("exampleplugins") do
			if entry:match("%.lua$") then
				entries[#entries + 1] = "exampleplugins/" .. entry
			end
		end

		assert.is_true(#entries > 0, "found no plugin entry points")

		local broken = {}
		for _, path in ipairs(entries) do
			local src = read(path)
			if #src == 0 then
				broken[#broken + 1] = path .. " is empty"
			elseif not src:match("register") then
				broken[#broken + 1] = path .. " never mentions register(ctx)"
			end
		end

		assert.are.same({}, broken)
	end)

	it("has no leftover references to the removed Gradient* widgets", function()
		-- Catches a call site that outlived its require, which would fail later and
		-- somewhere less obvious than a load error.
		local files = walk("src/lua", {})
		walk("plugins", files, { cli = true, native = true })

		local refs = {}
		for _, path in ipairs(files) do
			local n = 0
			for line in read(path):gmatch("[^\n]*") do
				n = n + 1
				-- Skip comments; several files explain the removal by name.
				if not line:match("^%s*%-%-") and line:match("Gradient%a*%s*[%.:]") then
					refs[#refs + 1] = path .. ":" .. n .. ": " .. line:gsub("^%s+", "")
				end
			end
		end

		assert.are.same({}, refs)
	end)
end)
