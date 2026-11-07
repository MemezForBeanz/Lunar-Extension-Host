local HostAPI = require("core.classes.HostAPI")
describe("local service controls", function()
	it("denies undeclared owners and headless hosts", function()
		local owner = {}
		local host = HostAPI:new({ iup = {} })
		host._manifest_by_owner = { [owner] = { capabilities = {} } }
		assert.is_nil(host:controlLocalService(owner, "start"))
		host._manifest_by_owner[owner].capabilities = { "local_service" }
		host.iup = nil
		assert.is_nil(host:controlLocalService(owner, "stop"))
	end)
	it("dispatches only status, start and stop for an allowed desktop owner", function()
		local saved = package.loaded["core.lib.Service"]
		local calls = 0
		package.loaded["core.lib.Service"] = { running = function() return true end,
			stop = function() calls = calls + 1; return true end }
		local host, owner = HostAPI:new({ iup = {} }), {}
		host._manifest_by_owner = { [owner] = { capabilities = { "local_service" } } }
		assert.is_true(host:controlLocalService(owner).running)
		assert.is_true(host:controlLocalService(owner, "stop"))
		assert.equal(1, calls)
		assert.is_nil(host:controlLocalService(owner, "install"))
		package.loaded["core.lib.Service"] = saved
	end)
end)
