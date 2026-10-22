local lfs = require("lfs")
local cjson = require("cjson")
local platform = require("core.platform")
local headless = require("core.headless")

local P = platform.path

local function write(path, text)
	local f = assert(io.open(path, "w"))
	f:write(text)
	f:close()
end

local sandbox_seq = 0
local function sandbox()
	sandbox_seq = sandbox_seq + 1
	local dir = P:join(platform.temp_dir(), string.format("lunar_headless_%d_%d_%d",
		os.time(), sandbox_seq, math.random(1e9)))
	lfs.mkdir(dir)
	return dir
end

local function plugin(root, name, manifest, code)
	local dir = P:join(root, name)
	lfs.mkdir(dir)
	write(P:join(dir, "manifest.json"), cjson.encode(manifest))
	write(P:join(dir, "init.lua"), code)
end

-- A server extension: a timer ticks three times, then it notifies and stops.
local SERVER = [[
local M = { name = "server" }
function M:register(ctx)
	_G.__hl.mode = ctx.mode
	local n = 0
	local t
	t = ctx:addTimer({ time = 5, run = true, action = function()
		n = n + 1
		if n == 3 then
			t:stop()
			ctx:notify({ title = "done", body = "3 ticks", kind = "success" }, M)
		end
	end }, M)
	ctx:onReady(function() _G.__hl.ready = true end, M)
end
function M:shutdown() _G.__hl.shutdown = true end
return M
]]

local GUI_ONLY = [[
_G.__hl.gui_ran = true
return { name = "gui", register = function() end }
]]

describe("core.headless", function()
	before_each(function() _G.__hl = {} end)

	describe("parse_args", function()
		it("reads the options", function()
			local o = assert(headless.parse_args({ "--pack", "acme", "--dev", "--extensions", "x",
				"--until-idle", "--for", "30", "--log-level", "debug" }))
			assert.are.equal("acme", o.pack)
			assert.is_true(o.dev)
			assert.are.same({ "x" }, o.extensions)
			assert.is_true(o.until_idle)
			assert.are.equal(30, o.seconds)
			assert.are.equal("DEBUG", o.log_level)
		end)

		it("refuses unknown options, missing values and --extensions without --dev", function()
			assert.is_nil((headless.parse_args({ "--nope" })))
			assert.is_nil((headless.parse_args({ "--pack" })))
			assert.is_nil((headless.parse_args({ "--for", "soon" })))
			local _, err = headless.parse_args({ "--extensions", "x" })
			assert.truthy(err:find("--dev", 1, true))
		end)
	end)

	describe("resolve_profile", function()
		local function resolver(profile)
			return function() return profile, { errors = {} } end
		end

		it("accepts a trusted pack that matches --pack", function()
			local p = { id = "acme", trusted = true, dir = "x" }
			assert.are.equal(p, headless.resolve_profile({ pack = "acme" }, resolver(p)))
		end)

		it("refuses an untrusted pack unless --dev", function()
			local p = { id = "acme", trusted = false, dir = "x" }
			local ok, err = headless.resolve_profile({ pack = "acme" }, resolver(p))
			assert.is_nil(ok)
			assert.truthy(err:find("not trusted", 1, true))
			assert.are.equal(p, headless.resolve_profile({ pack = "acme", dev = true }, resolver(p)))
		end)

		it("refuses a --pack that isn't the one resolved", function()
			local ok, err = headless.resolve_profile({ pack = "acme" }, resolver(nil))
			assert.is_nil(ok)
			assert.truthy(err:find("not installed", 1, true))
		end)

		it("runs neutral when no pack is installed and none was asked for", function()
			assert.is_false(headless.resolve_profile({}, resolver(nil)))
		end)
	end)

	it("loads only headless extensions, runs their timers, then shuts them down", function()
		local root = sandbox()
		plugin(root, "server", { schema_version = 2, id = "server", name = "Server", version = "1",
			host_api = 3, modes = { "headless" } }, SERVER)
		plugin(root, "gui", { schema_version = 2, id = "gui", name = "GUI", version = "1" }, GUI_ONLY)

		local app = assert(headless.boot({ profile = false, log_level = "ERROR",
			roots = { { dir = root, source = "test" } } }))
		local notes = {}
		app.host._notify_fn = function(spec) notes[#notes + 1] = spec end

		assert.are.equal(1, #app.extensions.extensions)
		assert.is_nil(_G.__hl.gui_ran)
		assert.are.equal("headless", _G.__hl.mode)
		assert.is_true(_G.__hl.ready)
		assert.are.equal("not for the headless host", app.extensions.skipped[1].reason)

		assert.are.equal("idle", headless.run(app, { until_idle = true, seconds = 10 }))
		assert.are.equal("done", notes[1] and notes[1].title)
		assert.is_true(_G.__hl.shutdown)
	end)

	it("stops at --for even when work remains", function()
		local root = sandbox()
		plugin(root, "forever", { schema_version = 2, id = "forever", name = "Forever", version = "1",
			host_api = 3, modes = { "headless", "gui" } }, [[
local M = {}
function M:register(ctx) ctx:addTimer({ time = 5, run = true, action = function() end }, M) end
return M
]])
		local app = assert(headless.boot({ profile = false, log_level = "ERROR",
			roots = { { dir = root, source = "test" } } }))
		assert.are.equal("deadline", headless.run(app, { seconds = 0.1 }))
	end)
end)
