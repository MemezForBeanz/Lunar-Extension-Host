local HostAPI = require("core.classes.HostAPI")
local Server = require("core.lib.HttpServer")
local Tokens = require("core.lib.HttpTokens")

describe("HostAPI HTTP routes", function()
	local host, owner, server
	before_each(function()
		server = Server.new({ tokens = { secret = "operator" } })
		host, owner = HostAPI:new({ http_server = server }), {}
		host:registerExtension(owner, { id = "scanner", capabilities = { "http" } })
	end)
	it("requires capability, rejects public and invalid routes", function()
		local other = {}
		host:registerExtension(other, { id = "other" })
		assert.is_nil((host:addRoute("GET", "/x", function() end, nil, other)))
		assert.is_nil((host:addRoute("GET", "/x", function() end, { public = true }, owner)))
		for _, path in ipairs({ "x", "/../x", "/%2e%2e/x", "/a?b", "/a\\b" }) do
			assert.is_nil((host:addRoute("GET", path, function() end, nil, owner)))
		end
		assert.is_nil((host:addRoute("bad method", "/x", function() end, nil, owner)))
		assert.are.equal(0, #server.routes)
	end)
	it("namespaces paths and removes only the owner's routes", function()
		local route = assert(host:addRoute("GET", "/runs/:id", function() end, nil, owner))
		assert.truthy(("/ext/scanner/runs/7"):match(route.pattern))
		assert.is_false(host:removeRoute(route, {}))
		assert.is_true(host:removeRoute(route, owner))
		assert.is_false(host:removeRoute(route, owner))
		assert(host:addRoute("GET", "/x", function() end, nil, owner))
		host:removeOwned(owner)
		assert.are.equal(0, #server.routes)
	end)
	it("refuses registration when HTTP is disabled or stopping", function()
		host._stopping = true
		assert.is_nil((host:addRoute("GET", "/x", function() end, nil, owner)))
		host._stopping, host._http_server = false, nil
		assert.is_nil((host:addRoute("GET", "/x", function() end, nil, owner)))
	end)
end)

describe("HTTP token files", function()
	it("parses names and tokens without accepting empty/ambiguous files", function()
		assert.are.same({ secret = "alice", other = "bob" }, Tokens.parse("alice secret\r\n\nbob other\n"))
		for _, text in ipairs({ "", " \n", "alice", "a x\nb x", "a x\na y", "a x extra" }) do
			local tokens, err = Tokens.parse(text)
			assert.is_nil(tokens); assert.is_string(err)
		end
	end)
	it("checks POSIX ownership, regular files and exact modes", function()
		local attr = { mode = "file", uid = 123, permissions = "rw-------" }
		assert(Tokens.validateAttributes(attr, 123))
		attr.uid, attr.permissions = 0, "rw-r-----"
		assert(Tokens.validateAttributes(attr, 123))
		attr.uid = 456
		assert.is_nil((Tokens.validateAttributes(attr, 123)))
		attr.uid, attr.permissions = 123, "rw-r--r--"
		assert.is_nil((Tokens.validateAttributes(attr, 123)))
		attr.permissions, attr.mode = "rw-------", "directory"
		assert.is_nil((Tokens.validateAttributes(attr, 123)))
	end)
end)
