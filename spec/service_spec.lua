local Instance = require("core.lib.Instance")
local Service = require("core.lib.Service")

describe("core.lib.Instance", function()
	it("keys a scope stably and differently per folder", function()
		assert.equal(Instance.key("a"), Instance.key("a"))
		assert.is_not.equal(Instance.key("C:/one"), Instance.key("C:/two"))
		assert.is_truthy(Instance.key("anything"):match("^%x%x%x%x%x%x%x%x$"))
	end)

	it("splits messages into lines and ignores blanks", function()
		assert.same({ "show", "lunar://host/settings" }, Instance.lines("show\r\n\nlunar://host/settings\n"))
		assert.same({}, Instance.lines(""))
	end)

	it("drops a line too long to be a real message", function()
		assert.same({ "show" }, Instance.lines(string.rep("x", 5000) .. "\nshow\n"))
	end)

	it("lets one holder claim a name and passes it a message", function()
		local name = "spec-" .. Instance.key(tostring(os.time()) .. tostring(os.clock()))
		local first = assert(Instance.acquire(name))
		assert.is_false(Instance.acquire(name))
		-- A sender writes and leaves before the holder polls, as a second launch does.
		assert.is_nil((first:poll())[1])
		assert.is_true(Instance.send(name, "show"))
		local got
		for _ = 1, 20 do
			got = first:poll()[1]
			if got then break end
		end
		assert.equal("show", got)
		first:release()
		local again = assert(Instance.acquire(name))
		again:release()
	end)

	it("reports nobody home when no copy runs", function()
		local ok, why = Instance.send("spec-nobody-here", "show")
		assert.is_nil(ok)
		assert.equal("no running copy answered", why)
	end)
end)

describe("core.lib.Service", function()
	it("makes a 64 digit random token", function()
		local a, b = assert(Service.randomToken()), assert(Service.randomToken())
		assert.equal(64, #a)
		assert.is_truthy(a:match("^%x+$"))
		assert.is_not.equal(a, b)
	end)

	it("runs on loopback with its own token and state by default", function()
		local opts = Service.headlessOptions({ listen = Service.DEFAULT_LISTEN })
		assert.equal("127.0.0.1:8421", opts.listen)
		assert.is_truthy(opts.tokens_file:find("service", 1, true))
		assert.is_truthy(opts.state_dir:find("state", 1, true))
		assert.is_false(opts.dev)
		assert.same({}, opts.extensions)
	end)

	it("passes settings through to the headless host", function()
		local opts = Service.headlessOptions({ listen = "127.0.0.1:9", dev = true, extensions = { "x" }, stop_grace = 5 })
		assert.is_true(opts.dev)
		assert.same({ "x" }, opts.extensions)
		assert.equal(5, opts.stop_grace)
	end)

	it("names the scheme from TLS", function()
		assert.equal("http://127.0.0.1:1", Service.endpointFor("127.0.0.1:1", false).url)
		assert.equal("https://127.0.0.1:1", Service.endpointFor("127.0.0.1:1", true).url)
	end)

	it("writes a systemd unit that restarts on failure", function()
		local text = Service.unitText("/opt/lunar/bin/lunar-cli", "service run")
		assert.is_truthy(text:find("ExecStart=/opt/lunar/bin/lunar-cli service run", 1, true))
		assert.is_truthy(text:find("Restart=on-failure", 1, true))
		assert.is_truthy(text:find("WantedBy=default.target", 1, true))
	end)
end)
