-- installer.plan: what a payload offers, what to preselect, the command line.

local lfs = require("lfs")
local plan = require("installer.plan")
local payload = require("spec.support.installer_payload")

describe("installer.plan", function()
	local root
	before_each(function() root = payload.new() end)
	after_each(function() payload.rmtree(root) end)

	describe("scan_extensions", function()
		it("lists folder and single-file extensions by display name", function()
			local exts = plan.scan_extensions(root .. "/plugins", { os = "linux" })
			local ids = {}
			for _, e in ipairs(exts) do ids[#ids + 1] = e.id end
			assert.are.same({ "alpha", "beta" }, ids)
			assert.are.equal("Alpha Tools", exts[1].name)
			assert.are.equal("1.2", exts[1].version)
			assert.are.equal("The Alpha Tools extension.", exts[1].description)
			assert.are.equal("dir", exts[1].kind)
			assert.are.equal("file", exts[2].kind)
			assert.are.same({ "beta.manifest.json" }, exts[2].companions)
		end)

		it("skips a bad manifest and says why", function()
			local _, skipped = plan.scan_extensions(root .. "/plugins", { os = "linux" })
			local by = {}
			for _, s in ipairs(skipped) do by[s.source] = s.reason end
			assert.is_truthy(by.delta:find("manifest decode failed", 1, true))
		end)

		it("skips extensions for another OS, and offers them there", function()
			local _, skipped = plan.scan_extensions(root .. "/plugins", { os = "linux" })
			local reason
			for _, s in ipairs(skipped) do if s.source == "gamma" then reason = s.reason end end
			assert.are.equal("needs windows", reason)
			local exts = plan.scan_extensions(root .. "/plugins", { os = "windows" })
			local found = false
			for _, e in ipairs(exts) do if e.id == "gamma" then found = true end end
			assert.is_true(found)
		end)

		it("skips an extension that needs a newer host", function()
			payload.write(root .. "/plugins/future/init.lua", "return {}")
			payload.write(root .. "/plugins/future/manifest.json",
				payload.manifest("future", "Future", { '"schema_version": 2', '"host_api": 99' }):gsub('"schema_version": 1,', ""))
			local _, skipped = plan.scan_extensions(root .. "/plugins", { os = "linux" })
			local reason
			for _, s in ipairs(skipped) do if s.source == "future" then reason = s.reason end end
			assert.is_truthy(reason and reason:find("newer Lunar"))
		end)

		it("derives a name from the file when there is no manifest", function()
			payload.write(root .. "/plugins/plain.lua", "return {}")
			local exts = plan.scan_extensions(root .. "/plugins", { os = "linux" })
			local plain
			for _, e in ipairs(exts) do if e.id == "plain" then plain = e end end
			assert.is_not_nil(plain)
			assert.are.equal("plain", plain.name)
		end)

		it("keeps what is not an extension aside, and never lists a manifest file on its own", function()
			local exts, _, support = plan.scan_extensions(root .. "/plugins", { os = "linux" })
			assert.are.same({ "README.md", "shared" }, support)
			for _, e in ipairs(exts) do assert.is_nil(e.id:find("manifest")) end
		end)

		it("reports two extensions with one id", function()
			payload.write(root .. "/plugins/zeta/init.lua", "return {}")
			payload.write(root .. "/plugins/zeta/manifest.json", payload.manifest("alpha", "Zeta"))
			local _, skipped = plan.scan_extensions(root .. "/plugins", { os = "linux" })
			local reason
			for _, s in ipairs(skipped) do if s.source == "zeta" then reason = s.reason end end
			assert.is_truthy(reason and reason:find("already used"))
		end)

		it("handles a missing plugins folder", function()
			local exts, skipped = plan.scan_extensions(root .. "/nope", { os = "linux" })
			assert.are.same({}, exts)
			assert.are.same({}, skipped)
		end)
	end)

	describe("read_payload", function()
		it("reads the extension list build.ps1 wrote", function()
			payload.write(root .. "/payload.json", [[{"version":"1.0.0","msi":"x.msi","extensions":[
				{"id":"alpha","name":"Alpha","version":"1.0","description":"d","feature":"Ft_ext_alpha"},
				{"id":"","name":"bad"}, {"id":"b","feature":"Ft_ext_b"}]}]])
			local info = plan.read_payload(root .. "/payload.json")
			assert.are.equal(2, #info.extensions)
			assert.are.equal("Ft_ext_alpha", info.extensions[1].feature)
			assert.are.equal("b", info.extensions[2].name)
		end)

		it("reports unreadable files", function()
			assert.is_nil(plan.read_payload(root .. "/missing.json"))
		end)
	end)

	describe("defaults and select", function()
		local exts = { { id = "a" }, { id = "b" }, { id = "c" } }

		it("checks everything on a first install", function()
			assert.are.same({ a = true, b = true, c = true }, plan.defaults(exts, nil))
		end)

		it("keeps an earlier choice and turns new extensions on", function()
			local d = plan.defaults(exts, { extensions = { "a" }, available = { "a", "b" } })
			assert.are.same({ a = true, b = false, c = true }, d)
		end)

		it("selects by id, all or none, and reports unknown ids", function()
			local picked, unknown = plan.select(exts, { "c", "a", "zz" })
			assert.are.same({ "a", "c" }, { picked[1].id, picked[2].id })
			assert.are.same({ "zz" }, unknown)
			assert.are.equal(3, #plan.select(exts, "all"))
			assert.are.equal(0, #plan.select(exts, "none"))
		end)
	end)

	describe("list_tree", function()
		it("lists folders before their contents", function()
			local dirs, files = plan.list_tree(root .. "/assets")
			assert.are.same({ "img" }, dirs)
			assert.are.same({ "img/logo.png", "theme.json" }, files)
		end)

		it("refuses a symbolic link", function()
			if require("core.platform").is_windows then return pending("no symbolic links without privileges") end
			lfs.link("/etc/passwd", root .. "/assets/evil", true)
			local dirs, err = plan.list_tree(root .. "/assets")
			assert.is_nil(dirs)
			assert.is_truthy(err:find("symbolic link"))
		end)
	end)

	describe("parse_args", function()
		it("defaults to a window", function()
			local o = plan.parse_args({})
			assert.is_false(o.quiet)
			assert.is_true(o.launch)
		end)

		it("reads the options", function()
			local o = plan.parse_args({ "--quiet", "--type", "system", "--extensions", "a,b", "--no-launch",
				"--root", "/r", "--home", "/h" })
			assert.is_true(o.quiet)
			assert.are.equal("system", o.type)
			assert.are.same({ "a", "b" }, o.extensions)
			assert.is_false(o.launch)
			assert.are.equal("/r", o.root)
			assert.are.equal("/h", o.home)
			assert.are.equal("none", plan.parse_args({ "--extensions", "none" }).extensions)
		end)

		it("rejects nonsense", function()
			assert.is_nil(plan.parse_args({ "--type", "root" }))
			assert.is_nil(plan.parse_args({ "--wat" }))
			assert.is_nil(plan.parse_args({ "--extensions" }))
		end)
	end)
end)
