local async = require("core.lib.async")

describe("async TCP probes", function()
	local resolver

	before_each(function()
		resolver = async.resolver
	end)
	after_each(function() async.resolver=resolver; async._test_gettime=nil; async._test_sleep=nil end)
	it("waits cooperatively for bounded resolver capacity and reports a distinct deadline", function()
		local now,attempts=0,0
		async._test_gettime=function() return now end
		async._test_sleep=function(dt) now=now+dt end
		async.resolver={start=function() attempts=attempts+1;return nil,"DNS resolver is busy" end,
			poll=function() error("no request was started") end}
		local ok,why=async.probeTcp("busy.invalid",80,.03)
		assert.is_false(ok)
		assert.equal("DNS resolver capacity timeout",why)
		assert.is_true(attempts>1)
	end)

	it("does not resolve numeric IPv4 addresses through the worker", function()
		local calls = 0
		async.resolver = {
			start = function() calls = calls + 1; error("unexpected DNS") end,
		}
		local ok, why = async.probeTcp("127.0.0.1", 1, 0.01)
		assert.is_false(ok)
		assert.is_not_nil(why)
		assert.are.equal(0, calls)
		async.resolver = resolver
	end)

	it("reports resolver failures without blocking the scheduler", function()
		local closed = 0
		async.resolver = {
			start = function() return {} end,
			poll = function() return "error", "stalled DNS" end,
			cancel = function() closed = closed + 1 end,
			close = function() closed = closed + 1 end,
		}
		local ok, why = async.probeTcp("black-duck.invalid", 443, 0.05)
		assert.is_false(ok)
		assert.are.equal("stalled DNS", why)
		assert.are.equal(2, closed)
		async.resolver = resolver
	end)

	it("connects using a resolved numeric address and closes the request", function()
		local old_socket = package.loaded.socket
		local closed, connected = 0, 0
		package.loaded.socket = {
			gettime = function() return 1 end,
			tcp = function()
				return {
					settimeout = function() end,
					connect = function(_, address)
						connected = connected + 1
						assert.are.equal("192.0.2.10", address)
						return 1
					end,
					close = function() end,
				}
			end,
		}
		async.resolver = {
			start = function() return {} end,
			poll = function() return "done", { "192.0.2.10" } end,
			close = function() closed = closed + 1 end,
		}
		local ok, why = async.probeTcp("example.invalid", 443, 1)
		assert.is_true(ok, why)
		assert.are.equal(1, connected)
		assert.are.equal(1, closed)
		package.loaded.socket = old_socket
		async.resolver = resolver
	end)

	it("keeps the bounded synchronous fallback without the native worker", function()
		local old_socket = package.loaded.socket
		package.loaded.socket = {
			gettime = function() return 1 end,
			tcp = function()
				return {
					settimeout = function(_, seconds) assert.are.equal(1, seconds) end,
					connect = function(_, address)
						assert.are.equal("fallback.invalid", address)
						return nil, "refused"
					end,
					close = function() end,
				}
			end,
		}
		async.resolver = nil
		local ok, why = async.probeTcp("fallback.invalid", 443, 1)
		assert.is_false(ok)
		assert.are.equal("refused", why)
		package.loaded.socket = old_socket
		async.resolver = resolver
	end)

	it("applies the end-to-end deadline while DNS remains pending", function()
		local now = 0
		local sleeps = 0
		local old_gettime, old_sleep = async._test_gettime, async._test_sleep
		async._test_gettime = function() return now end
		async._test_sleep = function(seconds) now = now + seconds; sleeps = sleeps + 1 end
		async.resolver = {
			start = function() return {} end,
			poll = function() return "pending" end,
			cancel = function() end,
			close = function() end,
		}
		local ok, why = async.probeTcp("pending.invalid", 443, 0.03)
		assert.is_false(ok)
		assert.are.equal("timeout resolving host", why)
		assert.is_true(sleeps > 0)
		async._test_gettime, async._test_sleep = old_gettime, old_sleep
		async.resolver = resolver
	end)
end)
