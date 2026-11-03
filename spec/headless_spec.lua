local lfs = require("lfs")
local cjson = require("cjson")
local platform = require("core.platform")
local headless = require("core.headless")

local P = platform.path

local function write(path, text)
	local f = assert(io.open(path, "w"))
	f:write(text)
	f:close()
end

local sandbox_seq = 0
local function sandbox()
	sandbox_seq = sandbox_seq + 1
	local dir = P:join(platform.temp_dir(), string.format("lunar_headless_%d_%d_%d",
		os.time(), sandbox_seq, math.random(1e9)))
	lfs.mkdir(dir)
	return dir
end

local function plugin(root, name, manifest, code)
	local dir = P:join(root, name)
	lfs.mkdir(dir)
	write(P:join(dir, "manifest.json"), cjson.encode(manifest))
	write(P:join(dir, "init.lua"), code)
end

-- A server extension: a timer ticks three times, then it notifies and stops.
local SERVER = [[
local M = { name = "server" }
function M:register(ctx)
	_G.__hl.mode = ctx.mode
	local n = 0
	local t
	t = ctx:addTimer({ time = 5, run = true, action = function()
		n = n + 1
		if n == 3 then
			t:stop()
			ctx:notify({ title = "done", body = "3 ticks", kind = "success" }, M)
		end
	end }, M)
	ctx:onReady(function() _G.__hl.ready = true end, M)
end
function M:shutdown() _G.__hl.shutdown = true end
return M
]]

local GUI_ONLY = [[
_G.__hl.gui_ran = true
return { name = "gui", register = function() end }
]]

describe("core.headless", function()
	before_each(function() _G.__hl = {} end)

	describe("parse_args", function()
		it("reads paired TLS flags and rejects incomplete or empty paths", function()
			local o = assert(headless.parse_args({ "--tls-cert", "cert.pem", "--tls-key", "key.pem" }))
			assert.are.equal("cert.pem", o.tls_cert)
			assert.are.equal("key.pem", o.tls_key)
			for _, flag in ipairs({ "--tls-cert", "--tls-key" }) do
				local parsed, err = headless.parse_args({ flag, "file.pem" })
				assert.is_nil(parsed)
				assert.matches("must be supplied together", err)
			end
			assert.is_nil((headless.parse_args({ "--tls-cert", "", "--tls-key", "" })))
		end)
		it("reads HTTP and state options without enabling HTTP by default", function()
			local o = assert(headless.parse_args({ "--listen", "127.0.0.1:8470", "--tokens-file", "keys", "--state-dir", "state" }))
			assert.are.equal("127.0.0.1:8470", o.listen)
			assert.are.equal("keys", o.tokens_file)
			assert.are.equal("state", o.state_dir)
			assert.is_nil(headless.parse_args({}).listen)
		end)
		it("reads the options", function()
			local o = assert(headless.parse_args({ "--pack", "acme", "--dev", "--extensions", "x",
				"--until-idle", "--for", "30", "--log-level", "debug" }))
			assert.are.equal("acme", o.pack)
			assert.is_true(o.dev)
			assert.are.same({ "x" }, o.extensions)
			assert.is_true(o.until_idle)
			assert.are.equal(30, o.seconds)
			assert.are.equal("DEBUG", o.log_level)
			assert.are.same({}, o.require)
			assert.are.equal(60, o.stop_grace)
		end)

		it("reads --require (repeatable) and --stop-grace", function()
			local o = assert(headless.parse_args({ "--require", "a", "--require", "b", "--stop-grace", "0" }))
			assert.are.same({ "a", "b" }, o.require)
			assert.are.equal(0, o.stop_grace)
			assert.is_nil((headless.parse_args({ "--stop-grace", "-1" })))
			assert.is_nil((headless.parse_args({ "--require" })))
		end)

		it("refuses unknown options, missing values and --extensions without --dev", function()
			assert.is_nil((headless.parse_args({ "--nope" })))
			assert.is_nil((headless.parse_args({ "--pack" })))
			assert.is_nil((headless.parse_args({ "--for", "soon" })))
			local _, err = headless.parse_args({ "--extensions", "x" })
			assert.truthy(err:find("--dev", 1, true))
		end)
	end)

	describe("resolve_profile", function()
		local function resolver(profile)
			return function() return profile, { errors = {} } end
		end

		it("accepts a trusted pack that matches --pack", function()
			local p = { id = "acme", trusted = true, dir = "x" }
			assert.are.equal(p, headless.resolve_profile({ pack = "acme" }, resolver(p)))
		end)

		it("refuses an untrusted pack unless --dev", function()
			local p = { id = "acme", trusted = false, dir = "x" }
			local ok, err = headless.resolve_profile({ pack = "acme" }, resolver(p))
			assert.is_nil(ok)
			assert.truthy(err:find("not trusted", 1, true))
			assert.are.equal(p, headless.resolve_profile({ pack = "acme", dev = true }, resolver(p)))
		end)

		it("refuses a --pack that isn't the one resolved", function()
			local ok, err = headless.resolve_profile({ pack = "acme" }, resolver(nil))
			assert.is_nil(ok)
			assert.truthy(err:find("not installed", 1, true))
		end)

		it("runs neutral when no pack is installed and none was asked for", function()
			assert.is_false(headless.resolve_profile({}, resolver(nil)))
		end)
	end)

	it("loads only headless extensions, runs their timers, then shuts them down", function()
		local root = sandbox()
		plugin(root, "server", { schema_version = 2, id = "server", name = "Server", version = "1",
			host_api = 3, modes = { "headless" } }, SERVER)
		plugin(root, "gui", { schema_version = 2, id = "gui", name = "GUI", version = "1" }, GUI_ONLY)

		local app = assert(headless.boot({ profile = false, log_level = "ERROR",
			roots = { { dir = root, source = "test" } } }))
		local notes = {}
		app.host._notify_fn = function(spec) notes[#notes + 1] = spec end

		assert.are.equal(1, #app.extensions.extensions)
		assert.is_nil(_G.__hl.gui_ran)
		assert.are.equal("headless", _G.__hl.mode)
		assert.is_true(_G.__hl.ready)
		assert.are.equal("not for the headless host", app.extensions.skipped[1].reason)

		assert.are.equal("idle", headless.run(app, { until_idle = true, seconds = 10 }))
		assert.are.equal("done", notes[1] and notes[1].title)
		assert.is_true(_G.__hl.shutdown)
	end)

	it("rejects invalid listener and token configuration at boot with exit 1", function()
		for _, endpoint in ipairs({ "8470", ":8470", "localhost:0", "localhost:65536", "localhost:abc" }) do
			local app, err = headless.boot({ listen = endpoint })
			assert.is_nil(app); assert.is_string(err)
		end
		assert.is_nil((headless.boot({ listen = "127.0.0.1:8470" })))
		assert.is_nil((headless.boot({ tokens_file = "missing" })))
		local real_stderr = io.stderr
		local said = {}
		io.stderr = { write = function(_, s) said[#said + 1] = s end }
		local ok, code = pcall(headless.main, { "--listen", "127.0.0.1:8470", "--tokens-file", "nonexistent-token-file" })
		io.stderr = real_stderr
		assert.is_true(ok, code)
		assert.are.equal(1, code)
		assert.truthy(table.concat(said):find("nonexistent-token-file", 1, true))
	end)

	it("requires TLS off loopback, including lookalike hosts and invalid IPv4", function()
		for _, host in ipairs({ "0.0.0.0", "192.168.1.2", "[::]", "[::ffff:127.0.0.1]",
			"127.example.com", "127.0.0.999", "0127.0.0.1", "localhost.example.com" }) do
			local app, err = headless.boot({ listen = host .. ":8470" })
			assert.is_nil(app)
			assert.are.equal("--listen on a non-loopback address requires --tls-cert and --tls-key", err)
		end
		for _, host in ipairs({ "127.0.0.1", "127.255.1.2", "[::1]", "localhost", "LOCALHOST" }) do
			local _, err = headless.boot({ listen = host .. ":8470" })
			assert.are.equal("--listen requires --tokens-file", err)
		end
		local _, err = headless.boot({ listen = "0.0.0.0:8470", tls_cert = "cert.pem", tls_key = "key.pem" })
		assert.are.equal("--listen requires --tokens-file", err)
	end)

	it("reads secrets from --secrets-dir instead of the keyring", function()
		local o = assert(headless.parse_args({ "--secrets-dir", "/etc/lunar/secrets" }))
		assert.are.equal("/etc/lunar/secrets", o.secrets_dir)
		local root = sandbox()
		plugin(root, "server", { schema_version = 2, id = "server", name = "Server", version = "1",
			host_api = 3, modes = { "headless" }, capabilities = { "secrets" } }, SERVER)
		local app = assert(headless.boot({ profile = false, log_level = "ERROR", secrets_dir = "/etc/lunar/secrets",
			roots = { { dir = root, source = "test" } } }))
		assert.are.equal("/etc/lunar/secrets", app.host._secret_store.dir)
		local ok, err = app.host:setSecret(app.extensions.extensions[1], "x", "y")
		assert.is_nil(ok)
		assert.truthy(err:find("read-only", 1, true))
		headless.run(app, { until_idle = true, seconds = 10 })
	end)

	it("keeps databases open through drain and extension shutdown", function()
		local HostAPI = require("core.classes.HostAPI")
		local host, owner, calls = HostAPI:new({}), {}, {}
		host:registerExtension(owner, { id = "db", capabilities = { "database" } })
		local db = { close = function(self) self.closed = true; calls[#calls + 1] = "close"; return true end }
		host:_record(owner).databases = { history = db }
		local app = { host = host, log = { info = function() end, error = error },
			loop = { run = function() return "stopped" end,
				drain = function()
					assert.is_true(host:isStopping()); assert.is_nil(db.closed)
					calls[#calls + 1] = "drain"; return true
				end, close = function() calls[#calls + 1] = "loop-close" end },
			extensions = { shutdownAll = function()
				assert.is_nil(db.closed); calls[#calls + 1] = "shutdown"
				host:removeOwned(owner)
			end } }
		headless.run(app, {})
		assert.are.same({ "drain", "shutdown", "close", "loop-close" }, calls)
	end)

	it("boots authenticated HTTP with public health, fails on bind conflict and releases its listener", function()
		local socket = require("socket")
		local copas = require("core.lib.async").copas
		local ffi = require("ffi")
		local root = sandbox()
		local tokens = P:join(root, "tokens")
		write(tokens, "operator secret\n")
		if ffi.os ~= "Windows" then
			ffi.cdef[[int chmod(const char *, unsigned int);]]
			assert.are.equal(0, ffi.C.chmod(tokens, 384))
		end
		local listener = assert(socket.bind("127.0.0.1", 0))
		local _, port = listener:getsockname()
		listener:close()
		local opts = { profile = false, roots = {}, log_level = "ERROR",
			listen = "127.0.0.1:" .. port, tokens_file = tokens, state_dir = root }
		local app = assert(headless.boot(opts))
		local owner = {}
		app.host:registerExtension(owner, { id = "scanner", capabilities = { "http" } })
		assert(app.host:addRoute("GET", "/private", function(req) return { auth = req.auth } end, nil, owner))
		local conflict, err = headless.boot(opts)
		assert.is_nil(conflict); assert.is_string(err)
		local responses, done, problem = {}, false, nil
		copas.addthread(function()
			local ok, why = pcall(function()
				for _, target in ipairs({ "/health", "/ext/scanner/private", "/ext/scanner/private" }) do
					local conn = copas.wrap(assert(socket.tcp()))
					conn:settimeout(2); assert(conn:connect("127.0.0.1", port))
					assert(conn:send("GET " .. target .. " HTTP/1.1\r\nHost: localhost\r\n"
						.. (#responses == 2 and "Authorization: Bearer secret\r\n" or "") .. "\r\n"))
					responses[#responses + 1] = assert(conn:receive("*l"))
					conn:close()
				end
			end)
			if not ok then problem = why end
			done = true
		end)
		local deadline = socket.gettime() + 4
		while not done and socket.gettime() < deadline do copas.step(0.01) end
		headless.run(app, { seconds = 0, stop_grace = 0 })
		os.remove(tokens); lfs.rmdir(root)
		assert.is_true(done); assert.is_nil(problem)
		assert.matches("200", responses[1]); assert.matches("401", responses[2]); assert.matches("200", responses[3])
		local rebound = assert(socket.bind("127.0.0.1", port)); rebound:close()
	end)

	it("fails to boot when a --require'd extension doesn't load", function()
		local root = sandbox()
		plugin(root, "gui", { schema_version = 2, id = "gui", name = "GUI", version = "1" }, GUI_ONLY)
		local app, err = headless.boot({ profile = false, log_level = "ERROR", require = { "gui" },
			roots = { { dir = root, source = "test" } } })
		assert.is_nil(app)
		assert.truthy(err:find("required extension 'gui' did not load: not for the headless host", 1, true))
		local _, err2 = headless.boot({ profile = false, log_level = "ERROR", require = { "nothere" },
			roots = { { dir = root, source = "test" } } })
		assert.truthy(err2:find("'nothere' did not load: not found", 1, true))
	end)

	it("boots when every --require'd extension loaded", function()
		local root = sandbox()
		plugin(root, "server", { schema_version = 2, id = "server", name = "Server", version = "1",
			host_api = 3, modes = { "headless" } }, SERVER)
		local app = assert(headless.boot({ profile = false, log_level = "ERROR", require = { "server" },
			roots = { { dir = root, source = "test" } } }))
		headless.run(app, { until_idle = true, seconds = 10 })
	end)

	it("on stop, sets isStopping and lets a running job finish before shutdown", function()
		local root = sandbox()
		plugin(root, "worker", { schema_version = 2, id = "worker", name = "Worker", version = "1",
			host_api = 3, modes = { "headless" } }, [[
local M = {}
function M:register(ctx)
	_G.__hl.ctx = ctx
end
function M:shutdown() _G.__hl.stopping_at_shutdown = _G.__hl.ctx:isStopping() end
return M
]])
		local app = assert(headless.boot({ profile = false, log_level = "ERROR",
			roots = { { dir = root, source = "test" } } }))
		assert.is_false(app.host:isStopping())
		local finished = false
		local left = 2
		app.loop._jobs = { active = function() return left end,
			tick = function() left = left - 1; if left == 0 then finished = true end end }
		app.loop:stop()
		headless.run(app, { seconds = 0, stop_grace = 5 })
		assert.is_true(finished)
		assert.is_true(_G.__hl.stopping_at_shutdown)
	end)

	it("stops at --for even when work remains", function()
		local root = sandbox()
		plugin(root, "forever", { schema_version = 2, id = "forever", name = "Forever", version = "1",
			host_api = 3, modes = { "headless", "gui" } }, [[
local M = {}
function M:register(ctx) ctx:addTimer({ time = 5, run = true, action = function() end }, M) end
return M
]])
		local app = assert(headless.boot({ profile = false, log_level = "ERROR",
			roots = { { dir = root, source = "test" } } }))
		assert.are.equal("deadline", headless.run(app, { seconds = 0.1 }))
	end)
end)
