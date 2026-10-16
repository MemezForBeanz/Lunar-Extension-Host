-- HostAPI secrets: stored in the OS store under a per-extension name, so one
-- extension can't read another's.

local HostAPI = require("core.classes.HostAPI")

local function host_with_store()
	local store = { data = {} }
	function store.secret_get(t)
		if store.data[t] == nil then return nil, "not found" end
		return store.data[t]
	end
	function store.secret_set(t, v) store.data[t] = v; return true end
	function store.secret_delete(t) store.data[t] = nil; return true end
	local host = HostAPI:new({ iup = {} })
	host._secret_store = store
	return host, store
end

describe("HostAPI secrets", function()
	it("stores per extension, under the extension's id", function()
		local host, store = host_with_store()
		local bd, other = {}, {}
		host:registerExtension(bd, { id = "scanner" })
		host:registerExtension(other, { id = "other" })

		assert.is_true(host:setSecret(bd, "api-token", "s3cret"))
		assert.are.equal("s3cret", store.data["Lunar Extension Host/scanner/api-token"])
		assert.are.equal("s3cret", host:getSecret(bd, "api-token"))
		local v, why = host:getSecret(other, "api-token")
		assert.is_nil(v)
		assert.are.equal("not found", why)

		assert.is_true(host:deleteSecret(bd, "api-token"))
		assert.is_nil((host:getSecret(bd, "api-token")))
	end)

	it("refuses unregistered owners, odd names and empty values", function()
		local host = host_with_store()
		local bd = {}
		assert.is_nil((host:getSecret(bd, "x")))
		host:registerExtension(bd, { id = "scanner" })
		for _, bad in ipairs({ "../x", "a/b", "", " x" }) do
			assert.is_nil((host:setSecret(bd, bad, "v")))
		end
		assert.is_nil((host:setSecret(bd, "token", "")))
	end)
end)
