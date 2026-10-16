local cjson = require("cjson")
local Updater = require("core.lib.Updater")

local ROOT = "\\\\files.example\\lunar"

-- A share as a table of path -> text.
local function share(files)
	return function(path) return files[path] end
end

local function check(files, installed, version)
	return Updater.check({ root = ROOT, app_version = version or "1.9.8", installed = installed, read = share(files) })
end

describe("Updater versions", function()
	it("accepts plain dotted numbers only", function()
		assert.are.same({ 1, 9, 8 }, Updater.parse_version("1.9.8"))
		assert.are.same({ 2 }, Updater.parse_version("2"))
		for _, bad in ipairs({ "../../2.0.0", "1.9.8-rc1", "1..2", "1.2.", ".1", "1.2.3.4.5", "123456.0", "", 1.2 }) do
			assert.is_nil(Updater.parse_version(bad), tostring(bad))
		end
	end)

	it("compares numerically and treats missing parts as zero", function()
		assert.are.equal(-1, Updater.compare("1.9.8", "1.10.0"))
		assert.are.equal(0, Updater.compare("2.0", "2.0.0"))
		assert.are.equal(1, Updater.compare("2.0.1", "2.0"))
		assert.is_nil(Updater.compare("1.9.8", "1.9.9-rc1"))
	end)
end)

describe("Updater.safe_path", function()
	it("accepts absolute drive and UNC paths", function()
		assert.is_true(Updater.safe_path("C:\\Program Files\\Lunar Extension Host\\LunarExtensionHost.exe"))
		assert.is_true(Updater.safe_path(ROOT .. "\\releases\\1.9.9\\LunarExtensionHost-1.9.9.msi"))
	end)

	it("refuses anything cmd or PowerShell would interpret, and relative paths", function()
		for _, bad in ipairs({
			ROOT .. "\\x\" & calc & \".msi", ROOT .. "\\%TEMP%\\a.msi", ROOT .. "\\a!b!.msi",
			ROOT .. "\\a'b.msi", ROOT .. "\\a`b.msi", ROOT .. "\\a|b", ROOT .. "\\a\nb",
			"relative\\a.msi", "\\\\host", ROOT .. "\\..\\other\\a.msi", "", nil,
		}) do
			assert.is_false(Updater.safe_path(bad), tostring(bad))
		end
	end)
end)

describe("Updater.check", function()
	local MANIFEST = ROOT .. "\\manifest.json"

	it("reports an app update and builds the installer path from the version", function()
		local r = check({ [MANIFEST] = cjson.encode({ latest = "1.9.9", setup = "evil\" & calc.msi" }) })
		assert.are.equal("available", r.status)
		assert.is_true(r.app_update)
		assert.are.equal(ROOT .. "\\releases\\1.9.9\\LunarExtensionHost-1.9.9.msi", Updater.installer_path(ROOT, r.latest))
	end)

	it("is current when nothing is newer", function()
		local r = check({ [MANIFEST] = cjson.encode({ latest = "1.9.8" }) })
		assert.are.equal("current", r.status)
		assert.is_false(r.app_update)
	end)

	it("lists newer versions of installed extensions", function()
		local r = check({
			[MANIFEST] = cjson.encode({ latest = "1.9.8" }),
			[ROOT .. "\\releases\\1.9.8\\release.json"] = cjson.encode({ extensions = {
				{ name = "Hello", version = "1.1" }, { name = "Other", version = "9" }, { name = "Hello2", version = "bad" },
			} }),
		}, { hello = "1.0", hello2 = "1.0" })
		assert.are.equal("available", r.status)
		assert.are.same({ "Hello (1.0 -> 1.1)" }, r.extensions)
	end)

	it("is unavailable, not current, when the share can't be read or lies", function()
		assert.are.equal("unavailable", check({}).status)
		assert.are.equal("unavailable", check({ [MANIFEST] = "not json" }).status)
		assert.are.equal("unavailable", check({ [MANIFEST] = cjson.encode({ latest = "..\\..\\x" }) }).status)
		local bad_root = Updater.check({ root = "relative", app_version = "1.0", read = share({}) })
		assert.are.equal("unavailable", bad_root.status)
	end)
end)

describe("Updater.relauncher_script", function()
	local MSI = ROOT .. "\\releases\\1.9.9\\LunarExtensionHost-1.9.9.msi"
	local EXE = "C:\\Program Files\\Lunar Extension Host\\LunarExtensionHost.exe"

	it("waits for the pid, installs elevated, relaunches and deletes itself", function()
		local s = assert(Updater.relauncher_script({ msi = MSI, exe = EXE, pid = 1234 }))
		assert.truthy(s:find('tasklist /FI "PID eq 1234"', 1, true))
		assert.truthy(s:find("-Verb RunAs -Wait", 1, true))
		assert.truthy(s:find(MSI, 1, true))
		assert.truthy(s:find('start "" "' .. EXE .. '"', 1, true))
		assert.truthy(s:find("\r\n", 1, true))
	end)

	it("refuses unsafe paths instead of escaping them", function()
		assert.is_nil((Updater.relauncher_script({ msi = ROOT .. "\\a\" & calc & \".msi", exe = EXE, pid = 1 })))
		assert.is_nil((Updater.relauncher_script({ msi = MSI, exe = "C:\\%x%\\a.exe", pid = 1 })))
	end)
end)
