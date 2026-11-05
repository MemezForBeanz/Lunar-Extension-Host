-- core.lsp.Registry and Discover: which server serves a file, where its
-- workspace is, and finding the executable.

local Registry = require("core.lsp.Registry")
local Diagnostics = require("core.lsp.Diagnostics")
local Discover = require("core.lsp.Discover")
local fake = require("spec.support.fake_lsp")

local WINDOWS = package.config:sub(1, 1) == "\\"
local function P(path) return WINDOWS and path or (path:gsub("^C:", ""):gsub("\\", "/")) end

local function setup(existing)
	local clock = fake.clock()
	local diagnostics = Diagnostics.new()
	local started, changes = {}, {}
	local files = {}
	for _, path in ipairs(existing or {}) do files[P(path)] = true end
	local registry = Registry.new({
		clock = clock, diagnostics = diagnostics,
		exists = function(path) return files[path] == true end,
		spawn = function(opts)
			local server = fake.server()
			server.spawn_opts = opts
			started[#started + 1] = server
			return server
		end,
		on_change = function(id) changes[#changes + 1] = id end,
	})
	return registry, { clock = clock, diagnostics = diagnostics, started = started, changes = changes }
end

local LUA = {
	id = "lua", name = "Lua", languages = { "lua" }, extensions = { ".lua" },
	root_markers = { ".luarc.json", ".git" },
	command = { argv = { "lua-language-server" } },
}
local C = {
	id = "c", name = "C and C++", languages = { "c", "cpp" },
	extensions = { ".c", ".h", ".cpp", "hpp" }, filenames = { "compile_flags.txt" },
	language_ids = { [".cpp"] = "cpp", hpp = "cpp" },
	root_markers = { "compile_commands.json", ".git" },
	command = function() return { argv = { "clangd" } } end,
}

describe("lsp Registry registration", function()
	it("stores a valid server and reports the change", function()
		local registry, t = setup()
		local entry = assert(registry:register(LUA, {}))
		assert.are.equal("Lua", entry.name)
		assert.are.equal(entry, registry:get("lua"))
		assert.are.same({ "lua" }, t.changes)
	end)

	it("refuses a bad or duplicate contribution with a reason", function()
		local registry = setup()
		local function refused(spec) local entry, err = registry:register(spec, {}); assert.is_nil(entry); return err end
		assert.matches("table of options", refused("lua"))
		assert.matches("id must use", refused({ id = "Lua Server", languages = { "lua" }, extensions = { ".lua" }, command = {} }))
		assert.matches("languages is required", refused({ id = "x", extensions = { ".x" }, command = {} }))
		assert.matches("extensions or filenames", refused({ id = "x", languages = { "x" }, command = {} }))
		assert.matches("command must be", refused({ id = "x", languages = { "x" }, extensions = { ".x" } }))
		assert(registry:register(LUA, {}))
		assert.matches("already registered", refused(LUA))
	end)
end)

describe("lsp Registry lookup", function()
	it("picks a server by extension or file name, with the right language id", function()
		local registry = setup()
		registry:register(LUA, {})
		registry:register(C, {})
		local entry, language = registry:serverFor(P("C:\\src\\Main.LUA"))
		assert.are.equal("lua", entry.id)
		assert.are.equal("lua", language)
		entry, language = registry:serverFor(P("C:\\src\\util.h"))
		assert.are.equal("c", entry.id)
		assert.are.equal("c", language)
		entry, language = registry:serverFor(P("C:\\src\\widget.cpp"))
		assert.are.equal("cpp", language)
		entry, language = registry:serverFor(P("C:\\src\\widget.hpp"))
		assert.are.equal("cpp", language)
		assert.are.equal("c", registry:serverFor(P("C:\\src\\compile_flags.txt")).id)
		assert.is_nil(registry:serverFor(P("C:\\src\\notes.txt")))
		assert.is_nil(registry:serverFor(P("C:\\src\\Makefile")))
	end)

	it("gives a file to the first server registered for it", function()
		local registry = setup()
		registry:register(LUA, {})
		registry:register({ id = "lua2", languages = { "lua" }, extensions = { ".lua" }, command = {} }, {})
		assert.are.equal("lua", registry:serverFor("a.lua").id)
	end)

	it("finds the workspace folder at the nearest root marker", function()
		local registry = setup({ "C:\\work\\proj\\.git", "C:\\work\\proj\\tools\\.luarc.json" })
		local entry = registry:register(LUA, {})
		assert.are.equal(P("C:\\work\\proj\\tools"), registry:rootFor(entry, P("C:\\work\\proj\\tools\\gen\\a.lua")))
		assert.are.equal(P("C:\\work\\proj"), registry:rootFor(entry, P("C:\\work\\proj\\src\\deep\\a.lua")))
	end)

	it("matches a *.ext marker against any file in the folder", function()
		local diagnostics = Diagnostics.new()
		local registry = Registry.new({
			diagnostics = diagnostics, spawn = function() end,
			exists = function() return false end,
			list = function(dir)
				if dir == P("C:\\work\\app") then return { "App.SLN", "readme.md" } end
				if dir == P("C:\\work\\app\\src\\core") then return { "core.csproj" } end
				return {}
			end,
		})
		local entry = registry:register({ id = "csharp", languages = { "csharp" }, extensions = { ".cs" },
			root_markers = { "*.sln", "*.csproj" }, command = {} }, {})
		-- Nearest folder with any marker wins.
		assert.are.equal(P("C:\\work\\app\\src\\core"), registry:rootFor(entry, P("C:\\work\\app\\src\\core\\a.cs")))
		assert.are.equal(P("C:\\work\\app"), registry:rootFor(entry, P("C:\\work\\app\\tools\\b.cs")))
	end)

	it("falls back to the file's own folder when there is no marker", function()
		local registry = setup()
		local entry = registry:register(LUA, {})
		assert.are.equal(P("C:\\scratch\\x"), registry:rootFor(entry, P("C:\\scratch\\x\\a.lua")))
	end)
end)

describe("lsp Registry clients", function()
	it("makes one client per server and workspace, started on first open", function()
		local registry, t = setup({ "C:\\work\\one\\.git", "C:\\work\\two\\.git" })
		registry:register(LUA, {})
		local a, entry, language = registry:clientFor(P("C:\\work\\one\\a.lua"))
		local b = registry:clientFor(P("C:\\work\\one\\sub\\b.lua"))
		local c = registry:clientFor(P("C:\\work\\two\\c.lua"))
		assert.are.equal(a, b)
		assert.are_not.equal(a, c)
		assert.are.equal("lua", entry.id)
		assert.are.equal("lua", language)
		assert.are.equal(P("C:\\work\\one"), a.root)
		assert.are.equal(0, #t.started)   -- nothing runs until a file is opened
		assert.are.equal("idle", registry:status("lua"))
		a:open(Registry.uri(P("C:\\work\\one\\a.lua")), "lua", "x = 1")
		for _ = 1, 3 do registry:pump() end
		assert.are.equal(1, #t.started)
		assert.are.equal("running", registry:status("lua"))
		assert.is_nil(registry:clientFor(P("C:\\work\\one\\readme.md")))
	end)

	it("files published diagnostics under the server's id", function()
		local registry, t = setup()
		registry:register(LUA, {})
		local path = P("C:\\work\\a.lua")
		local client = registry:clientFor(path)
		client:open(Registry.uri(path), "lua", "x = = 1")
		for _ = 1, 3 do registry:pump() end
		t.started[1]:notify("textDocument/publishDiagnostics", { uri = Registry.uri(path), diagnostics = {
			{ range = { start = { line = 0, character = 4 }, ["end"] = { line = 0, character = 5 } }, message = "unexpected symbol" },
		} })
		registry:pump()
		assert.are.equal(1, t.diagnostics:counts().error)
		assert.are.equal("lua", t.diagnostics:forUri(Registry.uri(path))[1].server)
	end)

	it("ends an owner's servers and withdraws their diagnostics on unload", function()
		local registry, t = setup()
		local lua_ext, c_ext = {}, {}
		registry:register(LUA, lua_ext)
		registry:register(C, c_ext)
		local lua_path, c_path = P("C:\\work\\a.lua"), P("C:\\work\\a.c")
		registry:clientFor(lua_path):open(Registry.uri(lua_path), "lua", "x")
		registry:clientFor(c_path):open(Registry.uri(c_path), "c", "int x;")
		for _ = 1, 3 do registry:pump() end
		t.diagnostics:set(Registry.uri(lua_path), "lua", { { message = "lua problem" } })
		t.diagnostics:set(Registry.uri(c_path), "c", { { message = "c problem" } })

		assert.are.equal(1, registry:removeOwned(lua_ext))
		assert.is_true(t.started[1].closed)
		assert.is_false(t.started[2].closed)
		assert.is_nil(registry:get("lua"))
		assert.is_nil(registry:serverFor(lua_path))
		assert.are.equal(1, t.diagnostics:counts().total)
		assert.are.equal("c problem", t.diagnostics:list()[1].message)
		assert.are.equal(0, registry:removeOwned(lua_ext))
		-- The id is free again, so a reloaded extension can register.
		assert(registry:register(LUA, lua_ext))
	end)

	it("clears a server's diagnostics when it fails for good", function()
		local registry, t = setup()
		registry:register({
			id = "broken", languages = { "x" }, extensions = { ".x" },
			command = function() return nil, "broken-server was not found on this computer." end,
		}, {})
		t.diagnostics:set("file:///stale.x", "broken", { { message = "stale" } })
		local client = registry:clientFor(P("C:\\work\\a.x"))
		client:open(Registry.uri(P("C:\\work\\a.x")), "x", "")
		assert.are.equal(0, t.diagnostics:counts().total)
		local state, detail = registry:status("broken")
		assert.are.equal("unavailable", state)
		assert.are.equal("broken-server was not found on this computer.", detail)
	end)

	it("probes a command without starting anything", function()
		local registry, t = setup()
		registry:register(LUA, {})
		registry:register({ id = "none", languages = { "n" }, extensions = { ".n" },
			command = function() return nil, "not installed" end }, {})
		assert.are.same({ "lua-language-server" }, registry:probe("lua").argv)
		local command, why = registry:probe("none")
		assert.is_nil(command)
		assert.are.equal("not installed", why)
		assert.are.equal(0, #t.started)
	end)

	it("stops everything on exit", function()
		local registry, t = setup()
		registry:register(LUA, {})
		registry:clientFor(P("C:\\work\\a.lua")):open(Registry.uri(P("C:\\work\\a.lua")), "lua", "x")
		registry:pump()
		assert.is_true(registry:isActive())
		registry:stopAll()
		assert.is_true(t.started[1].closed)
		assert.is_false(registry:isActive())
	end)
end)

describe("lsp Discover", function()
	local function files(list)
		local set = {}
		for _, path in ipairs(list) do set[path] = true end
		return function(path) return set[path] == true end
	end

	it("uses the configured path when it exists", function()
		local path, source = Discover.find({ label = "clangd", names = { "clangd" }, configured = ' "D:\\llvm\\bin\\clangd.exe" ' },
			{ exists = files({ "D:\\llvm\\bin\\clangd.exe" }), path = "", windows = true })
		assert.are.equal("D:\\llvm\\bin\\clangd.exe", path)
		assert.are.equal("settings", source)
	end)

	it("reports a configured path that is wrong instead of looking elsewhere", function()
		local path, why = Discover.find({ label = "clangd", names = { "clangd" }, configured = "D:\\gone\\clangd.exe" },
			{ exists = files({ "C:\\bin\\clangd.exe" }), path = "C:\\bin", windows = true })
		assert.is_nil(path)
		assert.matches("is set to D:\\gone\\clangd.exe in Settings, but that file does not exist", why)
	end)

	it("prefers a copy shipped with Lunar over PATH", function()
		local path, source = Discover.find({
			label = "lua-language-server", names = { "lua-language-server" },
			app_dir = "C:\\Lunar", bundled = { "servers\\lua\\bin\\lua-language-server.exe" },
		}, { exists = files({ "C:\\Lunar\\servers\\lua\\bin\\lua-language-server.exe", "C:\\bin\\lua-language-server.exe" }),
			path = "C:\\bin", windows = true })
		assert.are.equal("C:\\Lunar\\servers\\lua\\bin\\lua-language-server.exe", path)
		assert.are.equal("bundled", source)
	end)

	it("searches PATH with PATHEXT on Windows, first name first", function()
		local exists = files({ "C:\\tools\\pylsp.exe", "D:\\py\\pyright-langserver.cmd" })
		local path, source = Discover.find({ label = "Python server", names = { "pyright-langserver", "pylsp" } },
			{ exists = exists, path = 'C:\\empty;"C:\\tools";D:\\py', pathext = ".COM;.EXE;.BAT;.CMD", windows = true })
		assert.are.equal("C:\\tools\\pylsp.exe", path)
		assert.are.equal("path", source)
		assert.are.equal("D:\\py\\pyright-langserver.cmd",
			Discover.onPath({ "pyright-langserver" }, { exists = exists, path = "C:\\tools;D:\\py", windows = true }))
	end)

	it("searches PATH by exact name elsewhere", function()
		assert.are.equal("/usr/bin/clangd", Discover.onPath({ "clangd" },
			{ exists = files({ "/usr/bin/clangd" }), path = "/usr/local/bin:/usr/bin", windows = false }))
	end)

	it("says plainly that nothing was found, and how to fix it", function()
		local path, why = Discover.find({ label = "clangd", names = { "clangd" },
			install = "Install LLVM, or set the path in Settings > Language servers." },
			{ exists = files({}), path = "C:\\bin", windows = true })
		assert.is_nil(path)
		assert.are.equal("clangd was not found on this computer. Install LLVM, or set the path in Settings > Language servers.", why)
	end)
end)
