-- installer.windows: how the wizard's choices become an msiexec run.

local windows = require("installer.windows")
local backend = require("installer.backend")
local payload = require("spec.support.installer_payload")

describe("installer.windows", function()
	local exts = {
		{ id = "alpha", name = "Alpha", feature = "Ft_ext_alpha" },
		{ id = "beta-x", name = "Beta", feature = "Ft_ext_beta_x" },
	}

	it("always installs the core feature, then one per chosen extension", function()
		assert.are.same({ "Ft_Core" }, windows.features({}))
		assert.are.same({ "Ft_Core", "Ft_ext_alpha", "Ft_ext_beta_x" }, windows.features(exts))
	end)

	it("builds the msiexec command as an argument list", function()
		local argv = windows.msiexec_argv("C:\\Temp\\x y\\L.msi", { "Ft_Core", "Ft_ext_alpha" }, "C:\\Temp\\l.log",
			"C:\\Windows\\System32\\msiexec.exe")
		assert.are.same({ "C:\\Windows\\System32\\msiexec.exe", "/i", "C:\\Temp\\x y\\L.msi",
			"ADDLOCAL=Ft_Core,Ft_ext_alpha", "/qn", "/norestart", "/l*v", "C:\\Temp\\l.log" }, argv)
	end)

	it("names the unchosen extension features in REMOVE so unchecking one removes it", function()
		assert.are.same({ "Ft_ext_beta_x" }, windows.unchosen_features(exts, { exts[1] }))
		assert.are.same({}, windows.unchosen_features(exts, exts))
		local argv = windows.msiexec_argv("L.msi", { "Ft_Core" }, "l.log", "msiexec.exe", { "Ft_ext_alpha", "Ft_ext_beta_x" })
		assert.are.same({ "msiexec.exe", "/i", "L.msi", "ADDLOCAL=Ft_Core", "REMOVE=Ft_ext_alpha,Ft_ext_beta_x",
			"/qn", "/norestart", "/l*v", "l.log" }, argv)
	end)

	it("maps msiexec exit codes", function()
		assert.are.equal("ok", windows.map_exit(0).status)
		assert.are.equal("reboot", windows.map_exit(3010).status)
		assert.are.equal("reboot", windows.map_exit(1641).status)
		assert.are.equal("cancelled", windows.map_exit(1602).status)
		assert.are.equal("cancelled", windows.map_exit(1223).status)
		local busy = windows.map_exit(1618)
		assert.are.equal("error", busy.status)
		assert.is_truthy(busy.message:find("Another installation"))
		local other = windows.map_exit(1603)
		assert.are.equal("error", other.status)
		assert.is_truthy(other.message:find("1603", 1, true))
	end)

	it("preselects what is installed now, or everything on a first install", function()
		local calls
		local d, installed = windows.defaults(exts, function(code, features)
			calls = { code, features }
			return { Ft_Core = true, Ft_ext_beta_x = true }
		end)
		assert.is_true(installed)
		assert.are.same({ alpha = false, ["beta-x"] = true }, d)
		assert.are.equal(windows.UPGRADE_CODE, calls[1])
		assert.are.same({ "Ft_Core", "Ft_ext_alpha", "Ft_ext_beta_x" }, calls[2])

		d, installed = windows.defaults(exts, function() return nil end)
		assert.is_false(installed)
		assert.are.same({ alpha = true, ["beta-x"] = true }, d)
	end)

	describe("with a payload", function()
		local dir
		before_each(function()
			dir = payload.new()
			payload.write(dir .. "/payload.json", [[{"version":"1.2.3","msi":"LunarExtensionHost-1.2.3.msi","extensions":[
				{"id":"alpha","name":"Alpha","feature":"Ft_ext_alpha"},{"id":"beta","name":"Beta","feature":"Ft_ext_beta"}]}]])
		end)
		after_each(function() payload.rmtree(dir) end)

		it("starts msiexec elevated with the chosen features and maps its exit", function()
			local state = assert(windows.load(dir))
			local seen
			local fake = { code = nil, close = function() end, output = function() return "" end }
			fake.poll = function() return fake.code end
			local b = assert(backend.windows_install({ dir = dir, query = function() return nil end,
				elevate = function(argv) seen = argv return fake end, msiexec = "msiexec.exe" }))
			assert.are.equal("1.2.3", b.version)
			assert.are.equal(1, #b.types)
			local job = assert(b.start({ type = "system", ids = { "beta" } }))
			assert.are.equal("ADDLOCAL=Ft_Core,Ft_ext_beta", seen[4])
			assert.are.equal("REMOVE=Ft_ext_alpha", seen[5])
			assert.are.equal(state.msi_path, seen[3])
			assert.is_nil(job:tick())
			fake.code = 1603
			local r = job:tick()
			assert.are.equal("error", r.status)
			assert.is_truthy(r.detail:find("Lunar-Setup-1.2.3.log", 1, true))
		end)

		it("reports a declined UAC prompt", function()
			local b = assert(backend.windows_install({ dir = dir, query = function() return nil end,
				elevate = function() return nil, "cancelled" end }))
			local job, err = b.start({ type = "system", ids = {} })
			assert.is_nil(job)
			assert.are.equal("cancelled", err)
		end)

		it("fails clearly without a payload", function()
			local b, err = backend.windows_install({ dir = dir .. "/missing" })
			assert.is_nil(b)
			assert.is_truthy(err)
		end)
	end)
end)
