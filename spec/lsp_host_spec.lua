-- ctx:addLanguageServer: the one way a language server reaches the host, and the
-- four extensions that use it (Lua and C built in, Python and C# installable).

local HostAPI = require("core.classes.HostAPI")
local Manifest = require("core.lib.ExtensionManifest")
local fake = require("spec.support.fake_lsp")

local function fake_iup()
	return setmetatable({ DEFAULT = -2, timer = function(t) return t end },
		{ __index = function() return function() end end })
end

-- A host whose native `process` module hands out fake servers.
local function make_host(settings)
	local started = {}
	local saved = package.loaded["process"]
	package.loaded["process"] = { spawn = function(opts)
		local server = fake.server()
		server.spawn_opts = opts
		started[#started + 1] = server
		return server
	end }
	local values = settings or {}
	local host = HostAPI:new({
		iup = fake_iup(),
		app = { title = "Lunar", version = "0", dir = "C:\\Lunar" },
		settings = { get = function(_, key) return values[key] end },
	})
	local function restore() package.loaded["process"] = saved end
	return host, started, restore
end

local function owner_with(host, id, capabilities)
	local owner = {}
	assert(host:registerExtension(owner, assert(Manifest.validate({
		schema_version = 2, host_api = 4, id = id, name = id, version = "1",
		capabilities = capabilities or { "language_server" },
	}))))
	return owner
end

local SPEC = {
	id = "toy", languages = { "toy" }, extensions = { ".toy" },
	command = { argv = { "toy-server" } },
}

describe("ctx:addLanguageServer", function()
	local restore
	after_each(function() if restore then restore() end end)

	it("needs an owner whose manifest declares language_server", function()
		local host
		host, _, restore = make_host()
		local entry, err = host:addLanguageServer(SPEC, {})
		assert.is_nil(entry)
		assert.matches("language_server capability", err)
		entry, err = host:addLanguageServer(SPEC, owner_with(host, "plain", { "tabs" }))
		assert.is_nil(entry)
		assert.matches("language_server capability", err)
		assert.are.equal(0, #host:languageServers():servers())
	end)

	it("registers the server against the extension, starting nothing", function()
		local host, started
		host, started, restore = make_host()
		local entry = assert(host:addLanguageServer(SPEC, owner_with(host, "toy-ext")))
		assert.are.equal("toy-ext", entry.extension)
		assert.are.equal("toy", host:languageServers():serverFor("C:\\x\\a.toy").id)
		assert.are.equal(0, #started)
	end)

	it("passes a refusal from the registry back to the extension", function()
		local host
		host, _, restore = make_host()
		local owner = owner_with(host, "toy-ext")
		assert(host:addLanguageServer(SPEC, owner))
		local entry, err = host:addLanguageServer(SPEC, owner)
		assert.is_nil(entry)
		assert.matches("already registered", err)
	end)

	it("ends the server and withdraws its diagnostics when the extension unloads", function()
		local host, started
		host, started, restore = make_host()
		local owner = owner_with(host, "toy-ext")
		assert(host:addLanguageServer(SPEC, owner))
		local registry = host:languageServers()
		local client = registry:clientFor("C:\\x\\a.toy")
		client:open("file:///C:/x/a.toy", "toy", "text")
		for _ = 1, 3 do registry:pump() end
		assert.are.equal("running", client.state)
		host:languageDiagnostics():set("file:///C:/x/a.toy", "toy", { { message = "problem" } })

		host:removeOwned(owner)
		assert.is_true(started[1].closed)
		assert.is_nil(registry:serverFor("C:\\x\\a.toy"))
		assert.are.equal(0, host:languageDiagnostics():counts().total)
		assert.is_false(registry:isActive())
	end)

	it("finds a server through the user's setting first", function()
		local host
		host, _, restore = make_host({ ["lsp.toy.path"] = "C:\\definitely\\missing\\toy-server.exe" })
		local exe, why = host:findLanguageServer({ id = "toy", label = "toy-server", names = { "toy-server" } })
		assert.is_nil(exe)
		assert.matches("toy%-server is set to C:\\definitely\\missing\\toy%-server.exe in Settings", why)
	end)
end)

describe("the language server extensions", function()
	local EXTENSIONS = {
		{ dir = "plugins/lsp-lua", server = "lua", file = "init.lua", language = "lua" },
		{ dir = "plugins/lsp-c", server = "c", file = "widget.cpp", language = "cpp" },
		{ dir = "extensions/lsp-python", server = "python", file = "tool.py", language = "python" },
		{ dir = "extensions/lsp-csharp", server = "csharp", file = "Program.cs", language = "csharp" },
	}

	local function load_extension(dir)
		local manifest = assert(Manifest.load(dir .. "/manifest.json"))
		local module = assert(loadfile(dir .. "/init.lua"))()
		return manifest, module
	end

	for _, case in ipairs(EXTENSIONS) do
		it(case.dir .. " declares the capability and registers through the host", function()
			local manifest, module = load_extension(case.dir)
			assert.is_true(Manifest.hasCapability(manifest, "language_server"))
			assert.are.equal(4, manifest.host_api)
			assert.are.same({ case.server }, manifest.provides.language_servers)

			local host, _, restore = make_host()
			assert(host:registerExtension(module, manifest))
			module:register(host)
			local entry, language = host:languageServers():serverFor("C:\\proj\\" .. case.file)
			restore()
			assert.are.equal(case.server, entry.id)
			assert.are.equal(case.language, language)
			assert.are.equal(manifest.id, entry.extension)
		end)

		it(case.dir .. " says plainly when its server is not on the computer", function()
			local manifest, module = load_extension(case.dir)
			-- A configured path that does not exist is the deterministic "not found".
			local host, _, restore = make_host({ ["lsp." .. case.server .. ".path"] = "C:\\nowhere\\server.exe" })
			assert(host:registerExtension(module, manifest))
			module:register(host)
			local command, why = host:languageServers():probe(case.server)
			restore()
			assert.is_nil(command)
			assert.matches("in Settings, but that file does not exist", why)
		end)
	end

	it("keeps Python and C# out of the built-in plugins folder", function()
		local lfs = require("lfs")
		assert.is_nil(lfs.attributes("plugins/lsp-python"))
		assert.is_nil(lfs.attributes("plugins/lsp-csharp"))
		assert.are.equal("directory", lfs.attributes("plugins/lsp-lua", "mode"))
		assert.are.equal("directory", lfs.attributes("plugins/lsp-c", "mode"))
	end)
end)
