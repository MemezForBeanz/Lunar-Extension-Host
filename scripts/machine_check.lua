-- machine_check.lua
-- CLI verification harness for src/lua/core/lib/machine.lua.
-- Run from the repo root via:
--   build\bin\LunarExtensionHostCLI.exe scripts\machine_check.lua
--
-- machine.lua is pure Lua (optional luasocket for IP), so it can be exercised
-- without the GUI. This harness points package.path at the repo source tree and
-- drives identity resolution with a fake settings manager.

local lfs = require("lfs")

local repo = os.getenv("LUNAR_REPO") or lfs.currentdir()
package.path = table.concat({
	repo .. "\\src\\lua\\?.lua",
	repo .. "\\vendor\\luarocks-tree\\share\\lua\\5.1\\?.lua",
	package.path,
}, ";")

local machine = require("core.lib.machine")

local passed, failed = 0, 0

local function test(name, fn)
	io.write(string.format("  %-52s ", name .. " ..."))
	local ok, err = pcall(fn)
	if ok then
		passed = passed + 1
		print("PASS")
	else
		failed = failed + 1
		print("FAIL")
		print("    -> " .. tostring(err))
	end
end

local function assert_true(cond, label)
	if not cond then
		error((label or "assert_true") .. ": expected truthy")
	end
end

local function assert_eq(got, expected, label)
	if got ~= expected then
		error(string.format("%s: expected %q, got %q",
			label or "assert_eq", tostring(expected), tostring(got)))
	end
end

-- Minimal in-memory SettingsManager stand-in (get/set/save).
local function fake_settings(initial)
	local data = {}
	for k, v in pairs(initial or {}) do data[k] = v end
	return {
		saved = 0,
		get  = function(self, k) return data[k] end,
		set  = function(self, k, v) data[k] = v end,
		save = function(self) self.saved = self.saved + 1 end,
		_data = data,
	}
end

print("[machine]")

test("identify returns a table with expected fields", function()
	machine._reset()
	local info = machine.identify(fake_settings())
	assert_true(type(info) == "table", "info table")
	assert_true(info.machine_id ~= nil and info.machine_id ~= "", "machine_id populated")
	-- hostname/user come from the environment; on CI they should be present, but
	-- the field must at least exist (may be nil in a bare environment).
	assert_true(info.machine_id:match("^%x+%-%x+%-%x+%-%x+%-%x+$") ~= nil, "machine_id looks like a uuid")
end)

test("machine_id is persisted to settings on first resolve", function()
	machine._reset()
	local s = fake_settings()
	local info = machine.identify(s)
	assert_eq(s:get("machine_id"), info.machine_id, "persisted id matches")
	assert_true(s.saved >= 1, "settings saved")
end)

test("existing persisted machine_id is reused (stable across runs)", function()
	machine._reset()
	local s = fake_settings({ machine_id = "existing-1234" })
	local info = machine.identify(s)
	assert_eq(info.machine_id, "existing-1234", "reused id")
	assert_eq(s.saved, 0, "no re-save when id already present")
end)

test("identify caches result across calls", function()
	machine._reset()
	local first = machine.identify(fake_settings())
	local second = machine.identify(fake_settings({ machine_id = "should-be-ignored" }))
	assert_eq(first.machine_id, second.machine_id, "cached across calls")
end)

test("works without a settings manager (transient id)", function()
	machine._reset()
	local info = machine.identify(nil)
	assert_true(info.machine_id ~= nil and info.machine_id ~= "", "transient id populated")
end)

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
	os.exit(1)
end
