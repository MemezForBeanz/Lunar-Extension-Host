local RouteUri = require("core.lib.RouteUri")
local HostAPI = require("core.classes.HostAPI")

describe("RouteUri", function()
	it("round-trips plugin state with encoded parameters", function()
		local uri = assert(RouteUri.serialize({
			kind = "plugin",
			target = "buildqueue",
			action = "queue",
			params = { repo = "C:\\QA Tools", tool = "SMBIOS" },
		}))
		local route = assert(RouteUri.parse(uri))

		assert.are.equal("plugin", route.kind)
		assert.are.equal("buildqueue", route.target)
		assert.are.equal("queue", route.action)
		assert.are.equal("C:\\QA Tools", route.params.repo)
		assert.are.equal("SMBIOS", route.params.tool)
	end)

	it("rejects incomplete percent escapes and control characters", function()
		assert.is_nil(RouteUri.parse("lunar://plugin/buildqueue/queue?tool=%A"))
		assert.is_nil(RouteUri.parse("lunar://plugin/buildqueue/queue?tool=%0A"))
	end)

	it("serializes and parses lunar:// only", function()
		local uri = assert(RouteUri.serialize({ kind = "host", target = "settings" }))
		assert.are.equal("lunar://host/settings", uri)

		local route = assert(RouteUri.parse("lunar://plugin/buildqueue/queue?tool=SMBIOS"))
		assert.are.equal("plugin", route.kind)
		assert.are.equal("buildqueue", route.target)
		assert.are.equal("SMBIOS", route.params.tool)

		assert.is_nil(RouteUri.parse("http://host/settings"))
	end)
end)

describe("HostAPI routes", function()
	local function make_host()
		local active
		local tabs = { children = {} }
		local iup = {
			GetAttributeHandle = function() return active end,
			GetChild = function(_, index) return tabs.children[index + 1] end,
			SetAttribute = function(_, name, value)
				if name == "VALUEPOS" then active = tabs.children[tonumber(value) + 1] end
			end,
			GetAttribute = function() return nil end,
			GetFocus = function() return nil end,
			Refresh = function() end,
		}
		return HostAPI:new({ iup = iup, tabs = tabs }), tabs, function() return active end
	end

	it("dispatches owned plugin actions and serializes current state", function()
		local host, tabs = make_host()
		local owner = {}
		local tab = {}
		tabs.children[1] = tab
		host:_record(owner).tabs[1] = tab
		host._activeOwner = function() return owner end
		assert.is_true(host:registerExtension(owner, { id = "buildqueue", name = "Build Queue" }))
		host:registerRouteHandler("queue", function(params) return params.tool end, owner)
		host:registerRouteSerializer(function()
			return { action = "queue", params = { tool = "SMBIOS" } }
		end, owner)

		local ok, result = host:dispatchRoute("lunar://plugin/buildqueue/queue?tool=TXT")

		assert.is_true(ok)
		assert.are.equal("TXT", result)
		assert.are.equal("lunar://plugin/buildqueue/queue?tool=SMBIOS", host:currentRoute())
	end)

	it("rejects duplicate IDs and removes route ownership", function()
		local host = make_host()
		local first, second = {}, {}
		assert.is_true(host:registerExtension(first, { id = "same" }))
		local ok, err = host:registerExtension(second, { id = "same" })
		assert.is_nil(ok)
		assert.matches("duplicate", err)

		host:registerRouteHandler("open", function() end, first)
		host:removeOwned(first)
		local dispatched, route_err = host:dispatchRoute("lunar://plugin/same/open")
		assert.is_nil(dispatched)
		assert.are.equal("unknown_plugin", route_err.code)
	end)

	it("returns structured errors for unknown targets and actions", function()
		local host = make_host()
		local ok, err = host:dispatchRoute("lunar://host/missing")
		assert.is_nil(ok)
		assert.are.equal("unknown_host_target", err.code)

		local owner = {}
		assert.is_true(host:registerExtension(owner, { id = "sample" }))
		ok, err = host:dispatchRoute("lunar://plugin/sample/missing")
		assert.is_nil(ok)
		assert.are.equal("unknown_plugin_action", err.code)
	end)
end)
