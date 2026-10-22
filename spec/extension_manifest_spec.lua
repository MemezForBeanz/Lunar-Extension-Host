local Manifest = require("core.lib.ExtensionManifest")

describe("ExtensionManifest", function()
	it("normalizes valid declarative capabilities and provided surfaces", function()
		local manifest = assert(Manifest.validate({
			id = "sample.plugin",
			name = "Sample",
			version = "2.1",
			capabilities = { "routes", "settings" },
			provides = { tabs = { "Main" } },
		}, { id = "sample" }))

		assert.are.equal("sample.plugin", manifest.id)
		assert.are.same({ "routes", "settings" }, manifest.capabilities)
		assert.are.same({ "Main" }, manifest.provides.tabs)
	end)

	it("rejects an explicitly invalid ID instead of silently rewriting it", function()
		local manifest, err = Manifest.validate({
			id = "Invalid Plugin!",
			name = "Invalid",
			version = "1.0",
		}, { id = "invalid" })

		assert.is_nil(manifest)
		assert.matches("manifest id", err)
	end)

	it("rejects unsupported schema versions", function()
		local manifest, err = Manifest.validate({
			schema_version = 99,
			id = "future",
			name = "Future",
			version = "1.0",
		})

		assert.is_nil(manifest)
		assert.matches("unsupported manifest schema_version", err)
	end)

	it("restricts platforms only from schema_version 2", function()
		local base = { id = "bq", name = "Build Queue", version = "2.0" }
		local function with(extra)
			local t = {}
			for k, v in pairs(base) do t[k] = v end
			for k, v in pairs(extra) do t[k] = v end
			return Manifest.validate(t)
		end

		local m = assert(with({ schema_version = 2, platforms = { "windows" } }))
		assert.are.same({ "windows" }, m.platforms)
		assert.is_true(Manifest.supports(m, "windows"))
		assert.is_false(Manifest.supports(m, "linux"))

		local _, err = with({ schema_version = 1, platforms = { "windows" } })
		assert.matches("platforms needs schema_version 2", err)
		_, err = with({ schema_version = 2, platforms = { "beos" } })
		assert.matches("unknown platform", err)
		_, err = with({ schema_version = 2, platforms = {} })
		assert.matches("at least one", err)
	end)

	it("runs everywhere when platforms is omitted, in either schema", function()
		for _, v in ipairs({ 1, 2 }) do
			local m = assert(Manifest.validate({ schema_version = v, id = "x", name = "X", version = "1" }))
			assert.is_nil(m.platforms)
			assert.is_true(Manifest.supports(m, "linux"))
		end
	end)
	it("creates backward-compatible defaults when no manifest exists", function()
		local manifest = Manifest.defaultManifest({
			id = "legacy",
			name = "Legacy Plugin",
			version = "1.0",
		})

		assert.are.equal("legacy", manifest.id)
		assert.are.equal("implicit", manifest.manifest_source)
		assert.are.equal("Legacy Plugin", manifest.name)
	end)

	describe("modes", function()
		local base = { schema_version = 2, id = "srv", name = "Server", version = "1" }
		local function with(t)
			local m = {}
			for k, v in pairs(base) do m[k] = v end
			for k, v in pairs(t) do m[k] = v end
			return m
		end

		it("accepts gui and headless with host_api 3", function()
			local m = assert(Manifest.validate(with({ host_api = 3, modes = { "headless", "gui" } })))
			assert.are.same({ "headless", "gui" }, m.modes)
			assert.is_true(Manifest.supportsMode(m, "headless"))
			assert.is_true(Manifest.supportsMode(m, "gui"))
		end)

		it("needs host_api 3, schema 2, a known mode and at least one", function()
			local _, err = Manifest.validate(with({ modes = { "headless" } }))
			assert.truthy(err:find("host_api 3", 1, true))
			_, err = Manifest.validate({ id = "x", name = "X", version = "1", modes = { "gui" } })
			assert.truthy(err:find("schema_version 2", 1, true))
			_, err = Manifest.validate(with({ host_api = 3, modes = { "server" } }))
			assert.truthy(err:find("unknown mode", 1, true))
			_, err = Manifest.validate(with({ host_api = 3, modes = {} }))
			assert.truthy(err:find("at least one", 1, true))
		end)

		it("defaults to the desktop app only", function()
			local m = assert(Manifest.validate(base))
			assert.is_nil(m.modes)
			assert.is_true(Manifest.supportsMode(m, "gui"))
			assert.is_false(Manifest.supportsMode(m, "headless"))
			local h = assert(Manifest.validate(with({ host_api = 3, modes = { "headless" } })))
			assert.is_false(Manifest.supportsMode(h, "gui"))
		end)
	end)
end)