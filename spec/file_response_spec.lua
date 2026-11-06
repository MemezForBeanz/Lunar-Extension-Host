local Http = require("core.lib.HttpServer")
local Host = require("core.classes.HostAPI")

describe("native file response ownership", function()
	local previous, calls
	before_each(function()
		previous, calls = package.loaded.file_stream, {}
		package.loaded.file_stream = {
			target = function(root, name, mime)
				calls.target = { root, name, mime }
				return newproxy()
			end,
			cancel = function(task) calls[task] = true end,
		}
	end)
	after_each(function() package.loaded.file_stream = previous end)

	it("requires a registered http owner and rejects work when stopping", function()
		local host, owner = Host:new({}), {}
		assert.is_nil((host:fileResponse("root", "name", nil, owner)))
		host:registerExtension(owner, { id = "test", capabilities = { "http" } })
		local res = assert(host:fileResponse("root", "name", { mime = "video/mp4" }, owner))
		assert.are.same({ "root", "name", "video/mp4" }, calls.target)
		assert.are.same({}, res) -- no paths, handles or media on the response
		host._stopping = true
		assert.is_nil((host:fileResponse("root", "name", nil, owner)))
	end)

	it("cancels all native transfers without closing a worker's transport", function()
		local server = Http.new({ allow_anonymous = true })
		local task, closed = newproxy(), 0
		local conn = { close = function() closed = closed + 1 end }
		server.clients[conn], server.transfers[task] = task, conn
		assert.is_true(server:pendingFiles())
		server:stop()
		assert.is_true(calls[task])
		assert.are.equal(0, closed)
		assert.is_true(server:pendingFiles())
		server.transfers[task] = nil
		assert.is_false(server:pendingFiles())
	end)
end)
