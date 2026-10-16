local lfs = require("lfs")
local cjson = require("cjson")
local ExtensionManager = require("core.classes.ExtensionManager")
local platform = require("core.platform")

local P = platform.path

local function write(path, text)
	local f = assert(io.open(path, "w"))
	f:write(text)
	f:close()
end

-- A folder plugin that records it ran, with an optional manifest.
local function plugin(root, name, manifest)
	local dir = P:join(root, name)
	lfs.mkdir(dir)
	write(P:join(dir, "init.lua"),
		"_G.__ran = _G.__ran or {}\n" ..
		"table.insert(_G.__ran, " .. string.format("%q", root .. "|" .. name) .. ")\n" ..
		"return { name = " .. string.format("%q", name) .. ", register = function() end }\n")
	if manifest then write(P:join(dir, "manifest.json"), cjson.encode(manifest)) end
end

-- Unique per call: busted reseeds math.random, so a random name alone can hand
-- two tests the same folder (and one test would load the other's plugins).
local sandbox_seq = 0
local function sandbox()
	sandbox_seq = sandbox_seq + 1
	local base = P:join(platform.temp_dir(), string.format("lunar_ext_roots_%d_%d_%d",
		os.time(), sandbox_seq, math.random(1e9)))
	lfs.mkdir(base)
	local a, b = P:join(base, "builtin"), P:join(base, "pack")
	lfs.mkdir(a)
	lfs.mkdir(b)
	return a, b
end

-- Minimal HostAPI stand-in: records errors instead of showing dialogs.
local function ctx()
	local c = { errors = {} }
	c.iup = { Message = function(_, msg) c.errors[#c.errors + 1] = msg end }
	function c:setStatus() end
	function c:addVersionInfo() end
	function c:removeOwned() end
	function c:_resetMenuSeparators() end
	return c
end

describe("ExtensionManager roots", function()
	before_each(function() _G.__ran = {} end)

	it("loads every root in order and records each extension's source", function()
		local builtin, pack = sandbox()
		plugin(builtin, "alpha")
		plugin(pack, "beta")
		local mgr = ExtensionManager:new({
			{ dir = builtin, source = "built-in" }, { dir = pack, source = "org:acme" },
		})
		assert.are.equal(2, mgr:loadAll(ctx()))
		assert.are.equal("built-in", mgr.extensions[1].source)
		assert.are.equal("org:acme", mgr.extensions[2].source)
	end)

	it("refuses a second extension with the same id, without running it", function()
		local builtin, pack = sandbox()
		plugin(builtin, "dup")
		plugin(pack, "dup")
		local c = ctx()
		local mgr = ExtensionManager:new({
			{ dir = builtin, source = "built-in" }, { dir = pack, source = "org:acme" },
		})
		assert.are.equal(1, mgr:loadAll(c))
		assert.are.equal(1, #_G.__ran)
		assert.truthy(c.errors[1]:find("already loaded from built-in", 1, true))
	end)

	it("skips other-platform extensions and refuses newer host APIs before running them", function()
		local builtin = sandbox()
		local other = platform.is_windows and "linux" or "windows"
		plugin(builtin, "elsewhere", { schema_version = 2, id = "elsewhere", name = "Elsewhere",
			version = "1", platforms = { other } })
		plugin(builtin, "future", { schema_version = 2, id = "future", name = "Future",
			version = "1", host_api = 99 })
		plugin(builtin, "fine", { schema_version = 2, id = "fine", name = "Fine",
			version = "1", platforms = { platform.os } })
		local c = ctx()
		local mgr = ExtensionManager:new({ { dir = builtin, source = "built-in" } })
		assert.are.equal(1, mgr:loadAll(c))
		assert.are.equal(1, #_G.__ran)
		assert.are.equal("elsewhere", mgr.skipped[1].id)
		assert.truthy(c.errors[1]:find("needs host API 99", 1, true))
	end)

	it("ignores a root that doesn't exist unless asked to create it", function()
		local builtin = sandbox()
		local missing = P:join(builtin, "nope")
		local made = P:join(builtin, "made")
		local mgr = ExtensionManager:new({
			{ dir = missing, source = "org:x" }, { dir = made, source = "built-in", create = true },
		})
		assert.are.equal(0, mgr:loadAll(ctx()))
		assert.is_nil(lfs.attributes(missing))
		assert.are.equal("directory", lfs.attributes(made, "mode"))
	end)

	it("refuses an extension that renames itself at runtime", function()
		local builtin = sandbox()
		local dir = P:join(builtin, "sly")
		lfs.mkdir(dir)
		write(P:join(dir, "manifest.json"), cjson.encode({ schema_version = 2, id = "sly", name = "Sly", version = "1" }))
		write(P:join(dir, "init.lua"), "return { id = 'other', name = 'Sly', register = function() _G.__ran[#_G.__ran + 1] = 'registered' end }")
		local c = ctx()
		assert.are.equal(0, ExtensionManager:new(builtin):loadAll(c))
		assert.are.equal(0, #_G.__ran)
		assert.truthy(c.errors[1]:find("returns id 'other'", 1, true))
	end)

	it("still accepts a single folder", function()
		local builtin = sandbox()
		plugin(builtin, "solo")
		assert.are.equal(1, ExtensionManager:new(builtin):loadAll(ctx()))
	end)
end)
