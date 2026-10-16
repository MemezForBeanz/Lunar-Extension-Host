local http = require("core.lib.http")
local cjson = require("cjson")

describe("http.prepare", function()
	it("defaults to GET with checked TLS and a timeout", function()
		local p = assert(http.prepare({ url = "https://api.example.com/x", headers = { Accept = "text/plain" } }))
		assert.are.equal("GET", p.method)
		assert.are.equal("https", p.scheme)
		assert.are.equal("peer", p.verify)
		assert.are.equal(http.DEFAULT_TIMEOUT, p.timeout)
		assert.are.equal("text/plain", p.headers.accept)
	end)

	it("encodes json as a POST body", function()
		local p = assert(http.prepare({ url = "http://h/x", json = { a = 1 } }))
		assert.are.equal("POST", p.method)
		assert.are.same({ a = 1 }, cjson.decode(p.body))
		assert.are.equal("application/json", p.headers["content-type"])
		assert.are.equal(tostring(#p.body), p.headers["content-length"])
	end)

	it("caps the timeout", function()
		assert.are.equal(http.MAX_TIMEOUT, assert(http.prepare({ url = "http://h", timeout = 1e9 })).timeout)
	end)

	it("refuses what it can't send safely", function()
		for _, bad in ipairs({
			{ url = "ftp://h/x" }, { url = "file:///c:/x" }, { url = "http://h/a b" },
			{ url = "http://h", method = "TRACE" }, { url = "http://h", body = "x", json = {} },
			{ url = "http://h", headers = { ["x-a"] = "1\r\nInjected: yes" } },
			{ url = "http://h", headers = { ["bad:name"] = "1" } },
			{ url = "http://h", verify = "maybe" }, { url = "http://h", timeout = 0 }, "http://h",
		}) do
			local p, err = http.prepare(bad)
			assert.is_nil(p)
			assert.is_string(err)
		end
	end)
end)

describe("http.redirect_target", function()
	it("resolves relative locations", function()
		assert.are.equal("https://h/b/c", http.redirect_target("https://h/a/x", "/b/c"))
		assert.are.equal("https://other/z", http.redirect_target("https://h/a", "https://other/z"))
	end)

	it("refuses a downgrade to http and odd schemes", function()
		assert.is_nil((http.redirect_target("https://h/a", "http://h/a")))
		assert.is_nil((http.redirect_target("http://h/a", "file:///etc/passwd")))
		assert.is_nil((http.redirect_target("http://h/a", nil)))
		assert.are.equal("https://h/a", http.redirect_target("http://h/a", "https://h/a"))
	end)
end)

describe("http.clean_error", function()
	it("drops the source locations Lua errors pick up", function()
		assert.are.equal("TLS/SSL handshake failed: certificate verify failed", http.clean_error(
			"C:\\x\\vendor\\copas\\copas.lua:43: C:\\x\\vendor\\copas\\copas.lua:688: TLS/SSL handshake failed: certificate verify failed"))
		assert.are.equal("connection refused", http.clean_error("connection refused"))
	end)
end)

describe("http.connector (TLS)", function()
	local function fake_copas(cert)
		local log = {}
		local copas = {}
		function copas.wrap(skt, sslt)
			log.sslt = sslt
			local conn = { socket = { getpeercertificate = function() return cert end } }
			function conn.connect() return true end
			function conn.close() log.closed = true end
			return conn
		end
		function copas.settimeout(_, t) log.timeout = t return true end
		return copas, log
	end
	local socket = { tcp = function() return {} end }
	local function cert_for(name)
		return { extensions = function() return { ["2.5.29.17"] = { dNSName = { name } } } end,
			subject = function() return {} end }
	end

	it("checks that the certificate names the host", function()
		local p = assert(http.prepare({ url = "https://api.example.com/x", timeout = 7 }))
		local copas, log = fake_copas(cert_for("other.example.com"))
		local reqt = { url = p.url, host = "api.example.com", port = 80 }
		local conn = http.connector(p, copas, socket, { verify = "peer" })(reqt)
		assert.are.equal(443, reqt.port)
		assert.are.same({ names = "api.example.com" }, log.sslt.sni)
		local ok, err = conn:connect("api.example.com", 443)
		assert.is_nil(ok)
		assert.truthy(err:find("not valid for host", 1, true))
		assert.is_true(log.closed)
		conn:settimeout(60)
		assert.are.equal(7, log.timeout)
	end)

	it("accepts a matching certificate and keeps an explicit port", function()
		local p = assert(http.prepare({ url = "https://api.example.com:8443/x" }))
		local copas = fake_copas(cert_for("*.example.com"))
		local reqt = { url = p.url, host = "api.example.com", port = 8443 }
		local conn = http.connector(p, copas, socket, { verify = "peer" })(reqt)
		assert.are.equal(8443, reqt.port)
		assert.is_true(conn:connect("api.example.com", 8443))
	end)

	it("skips the host check only when verify is none", function()
		local p = assert(http.prepare({ url = "https://10.0.0.5/x", verify = "none" }))
		local copas = fake_copas(cert_for("someone.else"))
		local conn = http.connector(p, copas, socket, { verify = "none" })({ url = p.url, host = "10.0.0.5" })
		assert.is_true(conn:connect("10.0.0.5", 443))
	end)
end)

describe("http.request against a local server", function()
	local async = require("core.lib.async")
	if not async.available then
		pending("copas is not on the test path")
		return
	end
	local copas = async.copas
	local socket = require("socket")

	-- A tiny HTTP/1.1 server on a free port.
	local server = assert(socket.bind("127.0.0.1", 0))
	local _, port = server:getsockname()
	local base = "http://127.0.0.1:" .. port
	local ROUTES = {
		["/ok"] = { 200, '{"hello":"world"}' },
		["/missing"] = { 404, "nope" },
		["/move"] = { 302, "", "Location: /ok\r\n" },
		["/loop"] = { 302, "", "Location: /loop\r\n" },
		["/big"] = { 200, string.rep("x", 4096) },
	}
	copas.addserver(server, function(c)
		c = copas.wrap(c)
		local line = c:receive("*l")
		local path = line and line:match("^%u+ (%S+)") or "/"
		local body_len = 0
		repeat
			local h = c:receive("*l")
			body_len = tonumber(h and h:lower():match("^content%-length:%s*(%d+)")) or body_len
		until not h or h == ""
		local posted = body_len > 0 and c:receive(body_len) or nil
		local r = ROUTES[path] or { 200, posted or "" }
		c:send(string.format("HTTP/1.1 %d X\r\nContent-Length: %d\r\n%sConnection: close\r\n\r\n%s",
			r[1], #r[2], r[3] or "", r[2]))
		c:close()
	end)

	local function run(req)
		local res, err
		local done = false
		async.run(function() return http.request(req) end, function(ok, a, b)
			if ok then res, err = a, b else err = a end
			done = true
		end)
		local deadline = socket.gettime() + 5
		while not done and socket.gettime() < deadline do copas.step(0.05) end
		assert.is_true(done, "request did not finish")
		return res, err
	end

	it("returns the status, headers and body", function()
		local res = assert(run({ url = base .. "/ok" }))
		assert.are.equal(200, res.status)
		assert.is_true(res.ok)
		assert.are.same({ hello = "world" }, res:json())
		assert.are.equal("17", res.headers["content-length"])
	end)

	it("treats a 404 as a response, not an error", function()
		local res = assert(run({ url = base .. "/missing" }))
		assert.are.equal(404, res.status)
		assert.is_false(res.ok)
		assert.are.equal("nope", res.body)
	end)

	it("follows redirects for GET, but not forever", function()
		local res = assert(run({ url = base .. "/move" }))
		assert.are.equal(200, res.status)
		assert.are.equal(base .. "/ok", res.url)
		local none, err = run({ url = base .. "/loop" })
		assert.is_nil(none)
		assert.truthy(err:find("too many redirects", 1, true))
	end)

	it("sends a body and stops past max_bytes", function()
		local res = assert(run({ url = base .. "/echo", json = { n = 5 } }))
		assert.are.same({ n = 5 }, res:json())
		local none, err = run({ url = base .. "/big", max_bytes = 1000 })
		assert.is_nil(none)
		assert.truthy(err:find("larger than", 1, true))
	end)

	it("reports a refused connection as an error", function()
		local closed = assert(socket.bind("127.0.0.1", 0))
		local _, dead_port = closed:getsockname()
		closed:close()
		local none, err = run({ url = "http://127.0.0.1:" .. dead_port .. "/", timeout = 2 })
		assert.is_nil(none)
		assert.is_string(err)
	end)
end)

describe("HostAPI:http", function()
	local HostAPI = require("core.classes.HostAPI")

	local function make_host(result)
		-- Every iup call is a no-op here; only the request bookkeeping is under test.
		local iup = setmetatable({}, { __index = function() return function() end end })
		local host = HostAPI:new({ iup = iup, tabs = { children = {} } })
		local pending
		function host:runAsync(fn, cb) pending = function() cb(pcall(fn)) end return true end
		package.loaded["core.lib.http"] = { request = function() return result.res, result.err end }
		return host, function() pending() end
	end
	after_each(function() package.loaded["core.lib.http"] = nil end)

	it("calls back with the response", function()
		local host, finish = make_host({ res = { status = 200 } })
		local got
		host:http({ url = "http://h" }, function(res, err) got = { res, err } end, {})
		finish()
		assert.are.equal(200, got[1].status)
	end)

	it("drops the callback after cancel or when the owner unloads", function()
		local host, finish = make_host({ res = { status = 200 } })
		local calls = 0
		local h = host:http({ url = "http://h" }, function() calls = calls + 1 end, {})
		h.cancel()
		finish()
		local owner = {}
		local host2, finish2 = make_host({ res = { status = 200 } })
		host2:http({ url = "http://h" }, function() calls = calls + 1 end, owner)
		host2:removeOwned(owner)
		finish2()
		assert.are.equal(0, calls)
	end)

	it("passes transport errors through", function()
		local host, finish = make_host({ err = "connection refused" })
		local got
		host:http({ url = "http://h" }, function(res, err) got = { res, err } end, {})
		finish()
		assert.is_nil(got[1])
		assert.are.equal("connection refused", got[2])
	end)
end)
