local lfs = require("lfs")
local ExtensionManager = require("core.classes.ExtensionManager")
local platform = require("core.platform")

local P = platform.path

local function write(path, text)
	local f = assert(io.open(path, "w"))
	f:write(text)
	f:close()
end

local seq = 0
local function new_root()
	seq = seq + 1
	local dir = P:join(platform.temp_dir(), string.format("lunar_ext_modules_%d_%d_%d",
		os.time(), seq, math.random(1e9)))
	assert(platform.mkdirs(dir))
	return dir
end

-- A folder plugin whose init.lua is `init` and whose extra files are `files`
-- (relative path -> source).
local function plugin(root, name, init, files)
	local dir = P:join(root, name)
	lfs.mkdir(dir)
	write(P:join(dir, "init.lua"), init)
	for rel, text in pairs(files or {}) do
		local full = P:join(dir, (rel:gsub("/", platform.sep)))
		platform.mkdirs(P:dirname(full))
		write(full, text)
	end
	return dir
end

local function ctx()
	local c = { errors = {} }
	c.iup = { Message = function(_, msg) c.errors[#c.errors + 1] = msg end }
	function c:setStatus() end
	function c:addVersionInfo() end
	function c:removeOwned() end
	function c:_resetMenuSeparators() end
	return c
end

-- init.lua that exposes what `classes.Util` returned and a lazy requirer.
local INIT = [[
local Util = require("classes.Util")
return {
	name = "x",
	util = Util,
	lazy = function() return require("libs.Lazy") end,
	register = function() end,
}
]]

describe("ExtensionModules (per-extension require)", function()
	it("gives each extension its own modules, even with the same names", function()
		local root = new_root()
		plugin(root, "alpha", INIT, { ["classes/Util.lua"] = 'return "alpha util"' })
		plugin(root, "beta", INIT, { ["classes/Util.lua"] = 'return "beta util"' })
		local mgr = ExtensionManager:new(root)
		assert.are.equal(2, mgr:loadAll(ctx()))
		assert.are.equal("alpha util", mgr.extensions[1].util)
		assert.are.equal("beta util", mgr.extensions[2].util)
		assert.is_nil(package.loaded["classes.Util"])
	end)

	it("runs the current code after a reload", function()
		local root = new_root()
		local dir = plugin(root, "gamma", INIT, { ["classes/Util.lua"] = 'return "v1"' })
		local c = ctx()
		local mgr = ExtensionManager:new(root)
		mgr:loadAll(c)
		assert.are.equal("v1", mgr.extensions[1].util)
		write(P:join(dir, "classes", "Util.lua"), 'return "v2"')
		mgr:reloadAll(c)
		assert.are.equal("v2", mgr.extensions[1].util)
	end)

	it("resolves the extension's modules when required lazily, after loading", function()
		local root = new_root()
		plugin(root, "delta", INIT, {
			["classes/Util.lua"] = 'return "u"',
			["libs/Lazy.lua"] = 'return { lazy = true }',
		})
		local mgr = ExtensionManager:new(root)
		mgr:loadAll(ctx())
		assert.is_true(mgr.extensions[1].lazy().lazy)
		assert.is_nil(package.loaded["libs.Lazy"])
	end)

	it("keeps global reads and writes going to _G", function()
		local root = new_root()
		plugin(root, "eps", [[
			LUNAR_SPEC_GLOBAL = (LUNAR_SPEC_SEED or 0) + 1
			return { name = "eps", register = function() end }
		]])
		_G.LUNAR_SPEC_SEED = 41
		ExtensionManager:new(root):loadAll(ctx())
		assert.are.equal(42, _G.LUNAR_SPEC_GLOBAL)
		_G.LUNAR_SPEC_GLOBAL, _G.LUNAR_SPEC_SEED = nil, nil
	end)

	it("removes package.loaded entries an extension added from its own folder, and only those", function()
		local root = new_root()
		local dir = P:join(root, "zeta")
		plugin(root, "zeta", string.format([[
			-- An extension going around its own require, the old way.
			package.path = %q .. package.path
			local legacy = _G.require("legacy.Mod")
			local shared = _G.require("spec.support.config_sandbox")
			return { name = "zeta", legacy = legacy, shared = shared, register = function() end }
		]], dir .. platform.sep .. "?.lua;"), { ["legacy/Mod.lua"] = 'return "legacy"' })
		local saved_path = package.path
		local had_shared = package.loaded["spec.support.config_sandbox"]
		package.loaded["spec.support.config_sandbox"] = nil
		local mgr = ExtensionManager:new(root)
		mgr:loadAll(ctx())
		package.path = saved_path
		assert.are.equal("legacy", package.loaded["legacy.Mod"])
		mgr:shutdownAll()
		assert.is_nil(package.loaded["legacy.Mod"])
		assert.is_not_nil(package.loaded["spec.support.config_sandbox"])
		package.loaded["spec.support.config_sandbox"] = had_shared
	end)

	it("drops the modules of an extension that fails to register", function()
		local root = new_root()
		local dir = P:join(root, "eta")
		plugin(root, "eta", string.format([[
			package.path = %q .. package.path
			_G.require("broken.Mod")
			return { name = "eta", register = function() error("nope") end }
		]], dir .. platform.sep .. "?.lua;"), { ["broken/Mod.lua"] = 'return "b"' })
		local saved_path = package.path
		local c = ctx()
		assert.are.equal(0, ExtensionManager:new(root):loadAll(c))
		package.path = saved_path
		assert.is_nil(package.loaded["broken.Mod"])
		assert.truthy(c.errors[1]:find("nope", 1, true))
	end)
end)
