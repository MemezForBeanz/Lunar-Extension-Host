local HostAPI = require("core.classes.HostAPI")

describe("HostAPI service facade", function()
    it("dispatches routes and shortcuts and removes both on owner teardown", function()
        local iup = { CONTINUE = 1, IGNORE = -1 }
        local host = HostAPI:new({ iup = iup })
        local owner = {}
        local calls = 0

        assert.is_true(host:registerExtension(owner, { id = "service-spec" }))
        host:registerRouteHandler("open", function(params) return params.item end, owner)
        host:registerShortcut(42, function() calls = calls + 1 end, owner)

        local ok, item = host:dispatchRoute("lunar://plugin/service-spec/open?item=one")
        assert.is_true(ok)
        assert.are.equal("one", item)
        assert.are.equal(iup.IGNORE, host:_dispatchKey(42))
        assert.are.equal(1, calls)

        local removed, failures = host:removeOwned(owner)
        assert.is_true(removed)
        assert.are.equal(0, failures)
        assert.are.equal(iup.CONTINUE, host:_dispatchKey(42))
        assert.are.equal(1, calls)
        local dispatched, err = host:dispatchRoute("lunar://plugin/service-spec/open?item=two")
        assert.is_nil(dispatched)
        assert.are.equal("unknown_plugin", err.code)
    end)
end)
