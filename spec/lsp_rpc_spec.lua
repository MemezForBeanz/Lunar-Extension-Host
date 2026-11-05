-- core.lsp.Rpc: ids, replies, timeouts, cancellation and the server's requests.

local Json = require("core.lsp.Json")
local Rpc = require("core.lsp.Rpc")
local fake = require("spec.support.fake_lsp")

local function harness()
	local sent, errors = {}, {}
	local clock = fake.clock()
	local rpc = Rpc.new({
		send = function(text)
			sent[#sent + 1] = assert(Json.decode(text))
			return true
		end,
		clock = clock,
		on_error = function(message) errors[#errors + 1] = message end,
	})
	local function receive(message)
		message.jsonrpc = "2.0"
		rpc:handle(assert(Json.encode(message)))
	end
	return rpc, sent, receive, clock, errors
end

describe("lsp Rpc", function()
	it("numbers requests and routes each reply to its callback", function()
		local rpc, sent, receive = harness()
		local results = {}
		rpc:request("a", { x = 1 }, function(result) results.a = result end)
		rpc:request("b", nil, function(result) results.b = result end)
		assert.are.equal(1, sent[1].id)
		assert.are.equal(2, sent[2].id)
		assert.are.equal("2.0", sent[1].jsonrpc)
		assert.are.equal(2, rpc:pending())
		receive({ id = 2, result = "second" })
		receive({ id = 1, result = { ok = true } })
		assert.are.equal("second", results.b)
		assert.is_true(results.a.ok)
		assert.are.equal(0, rpc:pending())
	end)

	it("hands an error reply to the callback as an error", function()
		local rpc, _, receive = harness()
		local result, err = "unset", nil
		rpc:request("a", nil, function(r, e) result, err = r, e end)
		receive({ id = 1, error = { code = -32602, message = "bad params" } })
		assert.is_nil(result)
		assert.are.equal(-32602, err.code)
		assert.are.equal("bad params", err.message)
	end)

	it("treats a null result as no result, not as an error", function()
		local rpc, _, receive = harness()
		local called, result, err = false, "unset", "unset"
		rpc:request("textDocument/hover", nil, function(r, e) called, result, err = true, r, e end)
		receive({ id = 1, result = Json.null })
		assert.is_true(called)
		assert.is_nil(result)
		assert.is_nil(err)
	end)

	it("times a request out, tells the server, and ignores the late reply", function()
		local rpc, sent, receive, clock = harness()
		local calls, err = 0, nil
		rpc:request("slow", nil, function(_, e) calls, err = calls + 1, e end, { timeout = 5 })
		clock.advance(4)
		rpc:tick()
		assert.are.equal(0, calls)
		clock.advance(2)
		rpc:tick()
		assert.are.equal(1, calls)
		assert.is_true(err.timeout)
		assert.are.equal("$/cancelRequest", sent[2].method)
		assert.are.equal(1, sent[2].params.id)
		receive({ id = 1, result = "too late" })
		assert.are.equal(1, calls)
	end)

	it("cancels a request: callback once, $/cancelRequest sent", function()
		local rpc, sent, receive = harness()
		local calls, err = 0, nil
		local handle = rpc:request("completion", nil, function(_, e) calls, err = calls + 1, e end)
		assert.is_false(handle.done())
		assert.is_true(handle.cancel())
		assert.is_true(handle.done())
		assert.is_false(handle.cancel())
		assert.are.equal(1, calls)
		assert.is_true(err.cancelled)
		assert.are.equal("$/cancelRequest", sent[2].method)
		receive({ id = 1, result = {} })
		assert.are.equal(1, calls)
	end)

	it("answers a request from the server", function()
		local rpc, sent, receive = harness()
		rpc:onRequest("workspace/configuration", function(params)
			return Json.array({ params.items[1].section })
		end)
		receive({ id = "srv-1", method = "workspace/configuration", params = { items = { { section = "Lua" } } } })
		assert.are.equal("srv-1", sent[1].id)
		assert.are.same({ "Lua" }, sent[1].result)
	end)

	it("answers null for a handled request with nothing to say", function()
		local rpc, sent, receive = harness()
		rpc:onRequest("client/registerCapability", function() return nil end)
		receive({ id = 9, method = "client/registerCapability", params = {} })
		assert.are.equal(Json.null, sent[1].result)
		assert.is_nil(sent[1].error)
	end)

	it("refuses a request nobody handles with MethodNotFound", function()
		local rpc, sent, receive = harness()
		receive({ id = 4, method = "workspace/semanticTokens/refresh" })
		assert.are.equal(Rpc.ERRORS.MethodNotFound, sent[1].error.code)
	end)

	it("turns a throwing request handler into an error reply", function()
		local rpc, sent, receive = harness()
		rpc:onRequest("boom", function() error("handler broke") end)
		receive({ id = 5, method = "boom" })
		assert.are.equal(Rpc.ERRORS.InternalError, sent[1].error.code)
		assert.matches("handler broke", sent[1].error.message)
	end)

	it("dispatches notifications and survives a handler that throws", function()
		local rpc, _, receive, _, errors = harness()
		local seen
		rpc:onNotification("textDocument/publishDiagnostics", function(params) seen = params.uri end)
		rpc:onNotification("bad", function() error("oops") end)
		receive({ method = "textDocument/publishDiagnostics", params = { uri = "file:///a" } })
		receive({ method = "bad" })
		receive({ method = "nobody/listens" })
		assert.are.equal("file:///a", seen)
		assert.are.equal(1, #errors)
		assert.matches("oops", errors[1])
	end)

	it("reports invalid JSON and malformed messages without raising", function()
		local rpc, _, _, _, errors = harness()
		rpc:handle("{nope")
		rpc:handle('{"jsonrpc":"2.0"}')
		rpc:handle("42")
		assert.are.equal(3, #errors)
	end)

	it("fails every waiting request when the connection is lost", function()
		local rpc = harness()
		local errs = {}
		rpc:request("a", nil, function(_, e) errs[#errs + 1] = e end)
		rpc:request("b", nil, function(_, e) errs[#errs + 1] = e end)
		rpc:failAll("the server exited")
		assert.are.equal(2, #errs)
		assert.is_true(errs[1].closed)
		assert.are.equal("the server exited", errs[2].message)
		assert.are.equal(0, rpc:pending())
	end)

	it("reports a send failure to the caller and leaves nothing pending", function()
		local rpc = Rpc.new({ send = function() return nil, "stdin is closed" end })
		local handle, err = rpc:request("a", nil, function() end)
		assert.is_nil(handle)
		assert.are.equal("stdin is closed", err)
		assert.are.equal(0, rpc:pending())
	end)
end)
