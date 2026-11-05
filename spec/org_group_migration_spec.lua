local migration = require("core.lib.OrgGroupMigration")

describe("historical Microchip tool groups", function()
	local profiles = { { id = "microchip", tool_group = "Microchip Tools" } }
	local function group(name, children, source)
		return { t = "group", name = name, source = source or "manifest", children = children or {} }
	end

	it("merges old pack names and flattens obsolete extension groups including unloaded tabs", function()
		local server = group("Black Duck Server", { { t = "tab", key = "blackduck/1" } })
		local layout = { version = 3, children = {
			group("Black Duck Tools (microchip)", { server, { t = "tab", key = "blackduck/3" } }),
			group("Microchip Tools", { { t = "tab", key = "timeclock/1" } }),
			group("HPE Build Tools"),
		} }
		assert.is_true(migration.migrate(layout, profiles))
		assert.are.equal(2, #layout.children)
		assert.are.equal("Microchip Tools", layout.children[1].name)
		assert.are.same({ { t = "tab", key = "blackduck/1" }, { t = "tab", key = "blackduck/3" }, { t = "tab", key = "timeclock/1" } }, layout.children[1].children)
		assert.are.equal("HPE Build Tools", layout.children[2].name)
		assert.is_false(migration.migrate(layout, profiles))
	end)

	it("keeps user-created groups and inactive packs untouched", function()
		local layout = { children = { group("Black Duck Tools", {}, "user"), group("Black Duck Tools (microchip)") } }
		assert.is_false(migration.migrate(layout, {}))
		assert.is_true(migration.migrate(layout, profiles))
		assert.are.equal("Black Duck Tools", layout.children[1].name)
		assert.are.equal("Microchip Tools", layout.children[2].name)
	end)

	it("repairs pane layouts and combines matching nested manifest groups without duplicate tabs", function()
		local layout = { panes = { right = {
			group("Microchip Tools", { group("Server", { { t = "tab", key = "blackduck/1" } }) }),
			group("Black Duck Tools", { group("Server", { { t = "tab", key = "blackduck/1" }, { t = "tab", key = "blackduck/2" } }) }),
		} } }
		assert.is_true(migration.migrate(layout, profiles))
		assert.are.equal(1, #layout.panes.right)
		assert.are.equal(2, #layout.panes.right[1].children)
	end)
	it("repairs the existing layout into four direct tools and keeps HPE outside Microchip", function()
		local hpe = group("HPE Build Tools", { { t = "tab", key = "buildqueue/1" } })
		local microchip = group("Microchip Tools", { hpe })
		microchip.toolbar, microchip.active = "left", "group:HPE Build Tools"
		local server = group("Black Duck Server", {
			{ t = "tab", key = "blackduck/1" }, { t = "tab", key = "blackduck/2" }, { t = "tab", key = "blackduck/3" },
		})
		server.active = "blackduck/3"
		local layout = { children = { microchip, group("Group 4", {
			{ t = "tab", key = "timeclock/1" }, server,
		}, "user") } }
		assert.is_true(migration.migrate(layout, profiles))
		assert.equal(2, #layout.children)
		assert.equal(microchip, layout.children[1])
		assert.equal(hpe, layout.children[2])
		assert.equal("left", microchip.toolbar)
		assert.equal("blackduck/3", microchip.active)
		assert.equal(4, #microchip.children)
		for _, node in ipairs(microchip.children) do assert.equal("tab", node.t) end
		assert.is_false(migration.migrate(layout, profiles))
	end)

	it("flattens both Time Clock and Black Duck groups while preserving selection", function()
		local server = group("Black Duck Server", { { t = "tab", key = "blackduck/1" } })
		local clock = group("Time Clock", { { t = "tab", key = "timeclock/1" } })
		clock.active = "timeclock/1"
		local root = group("Microchip Tools", { server, clock })
		root.active = "group:Time Clock"
		local layout = { children = { root } }
		assert.is_true(migration.migrate(layout, profiles))
		assert.same({ { t = "tab", key = "blackduck/1" }, { t = "tab", key = "timeclock/1" } }, root.children)
		assert.equal("timeclock/1", root.active)
	end)

	it("follows the selected group instead of an inactive sibling's remembered tab", function()
		local server = group("Black Duck Server", { { t = "tab", key = "blackduck/2" } })
		server.active = "blackduck/2"
		local clock = group("Time Clock", { { t = "tab", key = "timeclock/1" } })
		clock.active = "timeclock/1"
		local root = group("Microchip Tools", { server, clock })
		root.active = "group:Black Duck Server"
		assert.is_true(migration.migrate({ children = { root } }, profiles))
		assert.equal("blackduck/2", root.active)
	end)

	it("leaves subsequent user grouping and toolbar placement alone", function()
		local custom = group("My reviews", { { t = "tab", key = "blackduck/3" } }, "user")
		local layout = { children = { group("Microchip Tools", { custom }), { t = "tab", key = "timeclock/1", toolbar = "left" } } }
		assert.is_false(migration.migrate(layout, profiles))
		assert.equal(custom, layout.children[1].children[1])
		assert.equal("left", layout.children[2].toolbar)
	end)

	it("does not mistake another pack's Server group for Black Duck", function()
		local server = group("Server", { { t = "tab", key = "other/1" } })
		local layout = { children = { group("Microchip Tools", { { t = "tab", key = "blackduck/1" } }), server } }
		assert.is_false(migration.migrate(layout, profiles))
		assert.equal(server, layout.children[2])
	end)
end)
