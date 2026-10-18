-- spec/support/config_sandbox.lua — run code against a throwaway per-user config root.
--
-- SettingsManager resolves its folder through core.platform: %APPDATA% on
-- Windows, $XDG_CONFIG_HOME on Linux, each followed by platform.APP_DIR_NAME.
-- LuaJIT has no setenv, so `with_root` stubs os.getenv for the per-user roots
-- (config, cache, home) while `fn` runs. Specs never read or write the user's
-- real folders this way.

local platform = require("core.platform")
local path = platform.path

local M = {}

local seq = 0

--- A fresh, empty folder under the OS temp dir. Unique per call: busted
-- reseeds math.random, so a random name alone can repeat across tests.
-- @tparam string prefix
-- @treturn string
function M.new_root(prefix)
	seq = seq + 1
	local dir = path:join(platform.temp_dir(),
		string.format("%s_%d_%d_%d", prefix, os.time(), seq, math.random(1e9)))
	assert(platform.mkdirs(dir))
	return dir
end

--- `root`'s Lunar folder (what `platform.config_dir()` returns inside `with_root`).
-- @tparam string root
-- @treturn string
function M.app_dir(root)
	return path:join(root, platform.APP_DIR_NAME)
end

--- Join path segments with the platform separator.
function M.join(...)
	return path:join(...)
end

local SANDBOXED = {
	APPDATA = true, LOCALAPPDATA = true,              -- Windows config / cache
	XDG_CONFIG_HOME = true, XDG_CACHE_HOME = true, HOME = true, -- Linux
}

--- Call `fn(...)` with every per-user root pointing at `root`.
-- @tparam string root
-- @tparam function fn
function M.with_root(root, fn, ...)
	local real = os.getenv
	os.getenv = function(k)
		if SANDBOXED[k] then return root end
		return real(k)
	end
	local ok, err = pcall(fn, ...)
	os.getenv = real
	if not ok then error(err, 0) end
end

--- Make `dir` (and parents) or fail the test.
function M.mkdir(dir)
	assert(platform.mkdirs(dir))
	return dir
end


return M
