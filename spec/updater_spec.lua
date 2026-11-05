local cjson = require("cjson")
local Updater = require("core.lib.Updater")

local ROOT = "\\\\files.example\\lunar"

local HASH = string.rep("a", 64)
local function check(opts)
	opts = opts or {}
	local release = opts.release or { version = opts.latest or "1.9.9", msi = "LunarExtensionHost-" .. (opts.latest or "1.9.9") .. ".msi",
		extensions = opts.extensions }
	local requests = {}
	local result = Updater.check({ app_version = opts.version or "1.9.8", installed = opts.installed, platform = opts.platform,
		request = function(req)
			requests[#requests + 1] = req
			if opts.transport_error then return nil, opts.transport_error end
			if opts.http_error then return { status = opts.http_error, body = "error" } end
			if req.url == Updater.LATEST_METADATA then
				return { status = 200, body = opts.body or cjson.encode(release) }
			end
			return { status = 200, body = opts.sums or HASH .. "  " .. release.msi .. "\n" }
		end })
	return result, requests
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
		assert.is_true(Updater.safe_path("C:\\Program Files\\Lunar Extension Host\\Lunar.exe"))
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

describe("Updater.check GitHub releases", function()
	it("uses latest release metadata with no share setting or credentials", function()
		local result, requests = check()
		assert.equal("available", result.status)
		assert.equal("https://github.com/MemezForBeanz/Lunar-Extension-Host/releases/latest/download/release.json", requests[1].url)
		assert.equal("peer", requests[1].verify)
		assert.is_nil(requests[1].headers.authorization)
	end)
	it("pins installer and checksums to the chosen version", function()
		local result, requests = check()
		assert.equal("available", result.status)
		assert.is_true(result.app_update)
		assert.equal(Updater.RELEASES .. "/download/v1.9.9/SHA256SUMS", requests[2].url)
		assert.equal(Updater.RELEASES .. "/download/v1.9.9/LunarExtensionHost-1.9.9.msi", result.installer.url)
		assert.equal(HASH, result.installer.sha256)
	end)
	it("is current without fetching installer checksums when nothing is newer", function()
		local result, requests = check({ latest = "1.9.8" })
		assert.equal("current", result.status)
		assert.is_false(result.app_update)
		assert.equal(1, #requests)
	end)
	it("never downgrades a newer build to update an extension", function()
		local result = check({ latest = "1.2.0", version = "1.5.0", installed = { hello = "1.0" },
			extensions = { { name = "Hello", version = "1.1" } } })
		assert.equal("current", result.status)
		assert.equal(0, #result.extensions)
	end)
	it("compares installed extension versions from the release metadata", function()
		local result = check({ latest = "1.9.8", installed = { hello = "1.0", broken = "1.0" }, extensions = {
			{ name = "Hello", version = "1.1" }, { name = "Other", version = "9" }, { name = "Broken", version = "bad" },
		} })
		assert.equal("available", result.status)
		assert.same({ "Hello (1.0 -> 1.1)" }, result.extensions)
	end)
	it("does not accept paths or pre-release tags as release versions", function()
		for _, bad in ipairs({ "../../1.9.9", "1.9.9-rc1", '1.9.9"', "1.9", "123456.0.0" }) do
			assert.equal("unavailable", check({ release = { version = bad } }).status)
		end
	end)
	it("reports network, HTTP and invalid metadata failures as unavailable", function()
		assert.equal("unavailable", check({ transport_error = "offline" }).status)
		assert.equal("unavailable", check({ http_error = 404 }).status)
		assert.equal("unavailable", check({ http_error = 403 }).status)
		assert.equal("unavailable", check({ body = "not JSON" }).status)
		assert.equal("unavailable", check({ body = "null" }).status)
		assert.equal("unavailable", check({ version = "invalid" }).status)
	end)
	it("refuses unexpected installer names instead of trusting a manifest path", function()
		local result = check({ release = { version = "1.9.9", msi = "evil.msi" } })
		assert.equal("unavailable", result.status)
	end)
	it("requires a published SHA-256 before offering a Windows install", function()
		local result = check({ sums = HASH .. "  other.msi\n" })
		assert.equal("unavailable", result.status)
		assert.is_nil(result.installer)
	end)
	it("offers Linux release downloads without trying to install an MSI", function()
		local result, requests = check({ platform = "linux", release = { version = "1.9.9" } })
		assert.equal("available", result.status)
		assert.is_nil(result.installer)
		assert.equal(Updater.RELEASES .. "/tag/v1.9.9", result.release_url)
		assert.equal(1, #requests)
	end)
end)

describe("Updater.checksum", function()
	it("accepts GNU text and binary formats and normalizes hex", function()
		assert.equal(HASH, Updater.checksum(HASH:upper() .. "  Lunar.msi\r\n", "Lunar.msi"))
		assert.equal(HASH, Updater.checksum(HASH .. " *Lunar.msi\n", "Lunar.msi"))
	end)
	it("requires an exact filename and a complete unambiguous hash", function()
		assert.is_nil((Updater.checksum(HASH .. "  not-Lunar.msi", "Lunar.msi")))
		assert.is_nil((Updater.checksum("abcd  Lunar.msi", "Lunar.msi")))
		assert.is_nil((Updater.checksum(HASH .. "  Lunar.msi\n" .. string.rep("b", 64) .. "  Lunar.msi", "Lunar.msi")))
	end)
end)

describe("Updater.relauncher_script", function()
	local MSI = ROOT .. "\\releases\\1.9.9\\LunarExtensionHost-1.9.9.msi"
	local EXE = "C:\\Program Files\\Lunar Extension Host\\Lunar.exe"

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
