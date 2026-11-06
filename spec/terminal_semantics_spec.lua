local Binder = require("core.ui.CodeBinder")
local Uri = require("core.lsp.Uri")
local Client = require("core.lsp.Client")
local Documents = require("core.lsp.Documents")

local function fixture(existing)
	local state = { doc = existing, opened = 0, closed = 0, cancelled = 0 }
	local client = { documents = { get = function() return state.doc end } }
	function client:retainSnapshot(uri, language, text)
		if state.doc and state.doc.text ~= text then return nil end
		local owned = not state.doc
		if owned then self:open(uri, language, text) end
		return function() if owned then self:close(uri) end end
	end
	function client:supports() return true end
	function client:open(_, language, text)
		state.opened = state.opened + 1
		state.language = language
		state.doc = { text = text }
	end
	function client:close() state.closed = state.closed + 1; state.doc = nil end
	function client:semanticTokens(uri, fn)
		state.uri, state.reply = uri, fn
		return { cancel = function() state.cancelled = state.cancelled + 1 end }
	end
	local registry = { runningClientFor = function() return client, "python" end }
	return registry, state
end

describe("printed file semantic binding", function()
	it("opens a snapshot with a running server and closes it after the reply", function()
		local registry, state = fixture()
		local received
		Binder.semanticSnapshot({ registry = registry, path = "test.py", text = "value",
			on_tokens = function(tokens) received = tokens end })
		assert.equal(1, state.opened); assert.equal("python", state.language)
		assert.equal(Uri.fromPath("test.py"), state.uri)
		state.reply({ { start = 0, length = 5, role = "property" } })
		assert.equal(1, state.closed); assert.equal("property", received[1].role)
	end)
	it("borrows an editor's matching document without closing it", function()
		local registry, state = fixture({ text = "value" })
		Binder.semanticSnapshot({ registry = registry, path = "test.py", text = "value", on_tokens = function() end })
		state.reply({})
		assert.equal(0, state.opened); assert.equal(0, state.closed)
	end)
	it("does not replace an editor's unsaved text for a print", function()
		local registry, state = fixture({ text = "unsaved" })
		assert.is_nil(Binder.semanticSnapshot({ registry = registry, path = "test.py", text = "disk" }))
		assert.equal(0, state.opened); assert.is_nil(state.reply)
	end)
	it("cancels pending work on clear and ignores late replies", function()
		local registry, state = fixture()
		local received = false
		local request = Binder.semanticSnapshot({ registry = registry, path = "test.py", text = "value",
			on_tokens = function() received = true end })
		request.cancel(); state.reply({}); request.cancel()
		assert.equal(1, state.closed); assert.is_false(received)
	end)
	it("leaves the lexer alone without a running server", function()
		assert.is_nil(Binder.semanticSnapshot({}))
		assert.is_nil(Binder.semanticSnapshot({ registry = { runningClientFor = function() end }, path = "x.py" }))
	end)
end)

describe("semantic snapshot document lifetime", function()
	local function client()
		local c = Client.new({ id = "test", command = function() end, spawn = function() end })
		c.state = "running"
		c.documents = Documents.new({ notify = function() end })
		return c
	end
	it("keeps a shared snapshot until the last print releases it", function()
		local c = client()
		local first = assert(c:retainSnapshot("file:///x.py", "python", "x"))
		local second = assert(c:retainSnapshot("file:///x.py", "python", "x"))
		first(); assert.is_not_nil(c.documents:get("file:///x.py"))
		second(); second(); assert.is_nil(c.documents:get("file:///x.py"))
	end)
	it("does not close a printed document that an editor adopted", function()
		local c = client()
		local release = assert(c:retainSnapshot("file:///x.py", "python", "x"))
		c:open("file:///x.py", "python", "x")
		release(); assert.is_not_nil(c.documents:get("file:///x.py"))
	end)
	it("defers an editor close while its print request is pending", function()
		local c = client()
		c:open("file:///x.py", "python", "x")
		local release = assert(c:retainSnapshot("file:///x.py", "python", "x"))
		c:close("file:///x.py"); assert.is_not_nil(c.documents:get("file:///x.py"))
		release(); assert.is_nil(c.documents:get("file:///x.py"))
	end)
end)
