-- platform.exe_dir: a packaged build never falls back to the working directory.

local platform = require("core.platform")
local lfs = require("lfs")

describe("platform.exe_dir", function()
	local saved_dir, saved_dev
	before_each(function() saved_dir, saved_dev = rawget(_G, "LUNAR_EXE_DIR"), rawget(_G, "LUNAR_DEV_BUILD") end)
	after_each(function() _G.LUNAR_EXE_DIR, _G.LUNAR_DEV_BUILD = saved_dir, saved_dev end)

	it("uses the folder the host reports", function()
		_G.LUNAR_EXE_DIR, _G.LUNAR_DEV_BUILD = "/opt/lunar", false
		assert.are.equal("/opt/lunar", platform.exe_dir())
	end)

	it("refuses to guess in a packaged build", function()
		_G.LUNAR_EXE_DIR, _G.LUNAR_DEV_BUILD = "", false
		assert.has_error(function() platform.exe_dir() end)
		_G.LUNAR_EXE_DIR = nil
		assert.has_error(function() platform.exe_dir() end)
	end)

	it("falls back to the working directory for dev builds and the CLI", function()
		_G.LUNAR_EXE_DIR, _G.LUNAR_DEV_BUILD = nil, true
		assert.are.equal(lfs.currentdir(), platform.exe_dir())
		_G.LUNAR_DEV_BUILD = nil   -- the CLI and the test runner don't set it
		assert.are.equal(lfs.currentdir(), platform.exe_dir())
	end)
end)
