local HttpServer = require("core.lib.HttpServer")
local copas = require("core.lib.async").copas
local socket = require("socket")
local cjson = require("cjson")

describe("HttpServer", function()
	it("fails closed: localhost by default, and no server without tokens or allow_anonymous", function()
		assert.has_error(function() HttpServer.new({ port = 0 }) end)
		assert.are.equal("127.0.0.1", HttpServer.new({ port = 0, tokens = { t = "n" } }).host)
	end)

	local srv, logs
	before_each(function()
		logs = {}
		srv = HttpServer.new({ host = "127.0.0.1", port = 0, max_body = 128, allow_anonymous = true,
			log = function(level, message) logs[#logs + 1] = { level, message } end })
		assert.is_true(srv:start())
		assert.is_true(srv.port > 0)
	end)
	after_each(function() srv:stop() end)

	local function raw_request(wire)
		local done, result, problem
		copas.addthread(function()
			local conn = copas.wrap(assert(socket.tcp()))
			conn:settimeout(2)
			local ok, err = pcall(function()
				assert(conn:connect("127.0.0.1", srv.port))
				assert(conn:send(wire))
				local first = assert(conn:receive("*l"))
				local headers = {}
				while true do
					local line = assert(conn:receive("*l"))
					if line == "" then break end
					local key, value = line:match("^([^:]+):%s*(.*)$")
					headers[key:lower()] = value
				end
				local body = ""
				local length = tonumber(headers["content-length"])
				if length > 0 then body = assert(conn:receive(length)) end
				assert.are.equal("close", headers.connection)
				local extra, closed = conn:receive(1)
				assert.is_nil(extra)
				assert.are.equal("closed", closed)
				result = { status = tonumber(first:match("^HTTP/1.1 (%d+)")), headers = headers, body = body }
			end)
			conn:close()
			if not ok then problem = err end
			done = true
		end)
		local deadline = socket.gettime() + 4
		while not done and socket.gettime() < deadline do copas.step(0.01) end
		assert.is_true(done, "request timed out")
		assert.is_nil(problem, logs[1] and logs[1][2])
		return result
	end

	local function request(method, path, headers, body)
		return raw_request(method .. " " .. path .. " HTTP/1.1\r\nHost: localhost\r\n"
			.. (headers or "") .. "\r\n" .. (body or ""))
	end

	it("serves JSON and a decoded request", function()
		srv:route("GET", "/api/runs/:id", function(req)
			assert.are.equal("GET", req.method)
			assert.are.equal("/api/runs/a%20b", req.path)
			assert.are.equal("localhost", req.headers.host)
			assert.matches("^127%.0%.0%.1:%d+$", req.client)
			return { id = req.params.id, query = req.query }
		end)
		local res = request("GET", "/api/runs/a%20b?q=hello+world&encoded=%26%3D&empty=&q=last+one")
		assert.are.equal(200, res.status)
		assert.are.equal("application/json; charset=utf-8", res.headers["content-type"])
		assert.are.same({ id = "a b", query = { q = "last one", encoded = "&=", empty = "" } }, cjson.decode(res.body))
	end)

	it("decodes a POST JSON body", function()
		srv:route("POST", "/echo", function(req)
			assert.are.equal('{"n":5}', req.body)
			return { status = 201, json = req.json }
		end)
		local res = request("POST", "/echo", "Content-Type: application/json; charset=utf-8\r\nContent-Length: 7\r\n", '{"n":5}')
		assert.are.equal(201, res.status)
		assert.are.same({ n = 5 }, cjson.decode(res.body))
	end)

	it("distinguishes unknown paths and methods", function()
		srv:route("POST", "/known", function() end)
		srv:route("GET", "/known", function() end)
		assert.are.equal(404, request("GET", "/missing").status)
		local res = request("DELETE", "/known")
		assert.are.equal(405, res.status)
		assert.are.equal("GET, POST", res.headers.allow)
	end)

	it("requires a valid bearer token and exposes its name", function()
		srv:stop()
		srv = HttpServer.new({ host = "127.0.0.1", port = 0, tokens = { secret = "alice", other = "bob" } })
		assert(srv:start())
		srv:route("GET", "/private", function(req) return { auth = req.auth } end)
		srv:route("GET", "/health", function() return { ok = true } end, { public = true })
		for _, header in ipairs({ "", "Authorization: Bearer wrong\r\n", "Authorization: Bearer secre\r\n" }) do
			local res = request("GET", "/private", header)
			assert.are.equal(401, res.status)
			assert.are.equal("Bearer", res.headers["www-authenticate"])
			assert.is_string(cjson.decode(res.body).error)
		end
		assert.are.same({ auth = "alice" }, cjson.decode(request("GET", "/private", "Authorization: Bearer secret\r\n").body))
		assert.are.equal(200, request("GET", "/health").status)
	end)

	it("rejects oversized bodies before waiting for them", function()
		assert.are.equal(413, request("POST", "/", "Content-Length: 129\r\n").status)
	end)

	it("logs handler tracebacks without exposing them", function()
		srv:route("GET", "/fail", function() error("sensitive detail") end)
		local res = request("GET", "/fail")
		assert.are.equal(500, res.status)
		assert.are.same({ error = "internal error" }, cjson.decode(res.body))
		assert.are.equal("error", logs[1][1])
		assert.matches("sensitive detail", logs[1][2])
		assert.matches("stack traceback", logs[1][2])
	end)

	it("removes routes by handle and returns 204 for nil", function()
		local handle = srv:route("GET", "/remove", function() end)
		assert.are.equal(204, request("GET", "/remove").status)
		assert.is_true(srv:unroute(handle))
		assert.is_false(srv:unroute(handle))
		assert.are.equal(404, request("GET", "/remove").status)
	end)

	it("closes the listener so its port can be rebound", function()
		local port = srv.port
		srv:stop()
		srv:stop()
		local listener = assert(socket.bind("127.0.0.1", port))
		listener:close()
	end)

	it("rejects malformed and ambiguous requests", function()
		for _, wire in ipairs({
			"nonsense\r\n\r\n", "GET / HTTP/1.1\r\n\r\n",
			"GET /%ZZ HTTP/1.1\r\nHost: h\r\n\r\n",
			"GET /?a=%Z HTTP/1.1\r\nHost: h\r\n\r\n",
			"POST / HTTP/1.1\r\nHost: h\r\nContent-Length: -1\r\n\r\n",
			"POST / HTTP/1.1\r\nHost: h\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n",
		}) do assert.are.equal(400, raw_request(wire).status) end
		assert.are.equal(501, request("POST", "/", "Transfer-Encoding: chunked\r\n").status)
		assert.are.equal(400, request("POST", "/", "Content-Type: application/json\r\nContent-Length: 1\r\n", "{").status)
	end)

	it("bounds header count and line size", function()
		local headers = {}
		for i = 1, 101 do headers[i] = "X-" .. i .. ": v\r\n" end
		assert.are.equal(400, request("GET", "/", table.concat(headers)).status)
		assert.are.equal(400, request("GET", "/", "X-Large: " .. string.rep("x", 8200) .. "\r\n").status)
	end)

	it("supports raw responses and contains serialization errors", function()
		srv:route("GET", "/raw", function()
			return { body = "hello", headers = { ["Content-Type"] = "text/plain", ["Content-Length"] = "999" } }
		end)
		local res = request("GET", "/raw")
		assert.are.equal("hello", res.body)
		assert.are.equal("5", res.headers["content-length"])
		srv:route("GET", "/invalid", function() return { json = { fn = function() end } } end)
		assert.are.equal(500, request("GET", "/invalid").status)
	end)

	it("fails closed when TLS configuration is incomplete", function()
		local tls = HttpServer.new({ host = "127.0.0.1", port = 0, allow_anonymous = true,
		tls = { certificate = "missing.pem" } })
		local ok, err = tls:start()
		assert.is_nil(ok)
		assert.is_string(err)
		assert.is_nil(tls.listener)
	end)

	it("matches literal punctuation and multiple parameters while handlers yield", function()
		srv:route("GET", "/v1.0/:owner/:id", function(req)
			copas.sleep(0.001)
			return req.params
		end)
		assert.are.equal(404, request("GET", "/v1X0/a/b").status)
		assert.are.same({ owner = "a+b", id = "c/d" }, cjson.decode(request("GET", "/v1.0/a+b/c%2Fd").body))
	end)

	it("bounds aggregate header size", function()
		local headers = {}
		for i = 1, 8 do headers[i] = "X-" .. i .. ": " .. string.rep("x", 4200) .. "\r\n" end
		-- Stop at the limit: an unread excess can make Windows discard the reply
		-- on close. The server must reject without waiting for the rest of the line.
		local wire = "GET / HTTP/1.1\r\nHost: localhost\r\n" .. table.concat(headers)
		assert.are.equal(400, raw_request(wire:sub(1, 32768)).status)
	end)

	it("times out an incomplete body without invoking its handler", function()
		srv.read_timeout = 0.05
		local called = false
		srv:route("POST", "/", function() called = true end)
		assert.are.equal(400, request("POST", "/", "Content-Length: 2\r\n", "x").status)
		assert.is_false(called)
	end)
end)
