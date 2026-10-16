-- Unique per call: busted reseeds math.random, so a random name alone can hand
-- two tests (or two runs) the same temp folder.
local __unique_seq = 0
local function __unique_suffix()
	__unique_seq = __unique_seq + 1
	return string.format("%d_%d_%d", os.time(), __unique_seq, math.random(1e9))
end

local lfs = require("lfs")
local platform = require("core.platform")
local posix = require("core.platform.posix")
local MotionClock = require("core.lib.MotionClock")
local MotionDirector = require("core.classes.MotionDirector")

describe("platform fixes", function()
	it("mkdirs creates missing parents", function()
		local base = platform.path:join(platform.temp_dir(), "lunar_mkdirs_" .. __unique_suffix())
		local deep = platform.path:join(base, "a", "b", "c")
		assert.is_true(platform.mkdirs(deep))
		assert.are.equal("directory", lfs.attributes(deep, "mode"))
		assert.is_true(platform.mkdirs(deep))  -- already there is fine
	end)

	it("takes the last domain/search line from resolv.conf", function()
		assert.are.equal("new.example", posix.parse_resolv_domain(
			"search old.example other.example\nnameserver 10.0.0.1\nsearch new.example\n"))
		assert.are.equal("corp.example", posix.parse_resolv_domain("search a.example\ndomain corp.example # comment\n"))
		assert.is_nil(posix.parse_resolv_domain("nameserver 10.0.0.1\n"))
	end)

	it("turns motion off when no precise clock is available", function()
		local saved = MotionClock.available
		MotionClock.available = false
		local ok, d = pcall(MotionDirector.new, MotionDirector, { enabled = true, respect_system = false })
		MotionClock.available = saved
		assert(ok, d)
		assert.is_false(d:enabled())
		-- An injected clock (tests) still counts as precise.
		assert.is_true(MotionDirector:new({ clock = function() return 0 end, respect_system = false }):enabled())
	end)
end)