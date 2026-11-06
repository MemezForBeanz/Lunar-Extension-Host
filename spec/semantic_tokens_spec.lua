local Tokens = require("core.lsp.SemanticTokens")
local Client = require("core.lsp.Client")
local Json = require("core.lsp.Json")
local fake = require("spec.support.fake_lsp")
local legend = { tokenTypes = { "keyword", "variable", "string" }, tokenModifiers = { "declaration", "readonly" } }

describe("semantic token decoding", function()
	it("decodes same-line and new-line deltas with the server legend", function()
		local tokens = assert(Tokens.decode({ 0, 0, 3, 0, 0, 0, 4, 1, 1, 3, 1, 0, 3, 2, 0 }, legend, "let x\nabc", "utf-16"))
		assert.equal(0, tokens[1].start); assert.equal("keyword", tokens[1].role)
		assert.equal(4, tokens[2].start); assert.same({ "declaration", "readonly" }, tokens[2].modifiers)
		assert.equal(6, tokens[3].start); assert.equal(0, tokens[3].column)
	end)
	it("converts UTF-16 columns across supplementary Unicode characters", function()
		local tokens = assert(Tokens.decode({ 0, 2, 1, 1, 0 }, legend, "\240\159\152\128x", "utf-16"))
		assert.equal(4, tokens[1].start); assert.equal(1, tokens[1].length)
	end)
	it("preserves CRLF byte offsets and UTF-8 positions", function()
		local tokens = assert(Tokens.decode({ 1, 2, 1, 1, 0 }, legend, "a\r\n\195\169x", "utf-8"))
		assert.equal(5, tokens[1].start)
	end)
	it("rejects malformed integers, incomplete tuples, and out-of-document lines", function()
		for _, data in ipairs({ { 0 }, { -1, 0, 1, 0, 0 }, { 0, 0.5, 1, 0, 0 }, { 0, 0, 1, 9, 0 }, { 3, 0, 1, 0, 0 } }) do
			assert.is_nil(Tokens.decode(data, legend, "x"))
		end
		assert.is_nil(Tokens.decode({}, {}, ""))
	end)
	it("handles empty tokens and an unknown named token type", function()
		assert.same({}, Tokens.decode({}, legend, ""))
		assert.equal("text", Tokens.decode({ 0, 0, 1, 0, 0 }, { tokenTypes = { "custom" } }, "x")[1].role)
	end)
	it("applies ordered delta edits against the original array", function()
		local original = { 0, 0, 1, 0, 0, 0, 2, 1, 1, 0 }
		assert.same({ 0, 0, 1, 0, 0, 1, 0, 2, 2, 0 }, Tokens.applyDelta(original,
			{ { start = 5, deleteCount = 5, data = { 1, 0, 2, 2, 0 } } }))
		assert.equal(10, #original)
		assert.is_nil(Tokens.applyDelta(original, { { start = 11, deleteCount = 0 } }))
		assert.is_nil(Tokens.applyDelta(original, { { start = 5, deleteCount = 2 }, { start = 3, deleteCount = 0 } }))
	end)
end)

describe("semantic token protocol", function()
	it("advertises only implemented token features", function()
		local caps = Client.capabilities().textDocument.semanticTokens
		assert.is_true(caps.requests.full); assert.is_false(caps.dynamicRegistration)
		assert.same({ "relative" }, caps.formats); assert.is_false(caps.multilineTokenSupport)
	end)
	it("requests a full result and returns decoded byte ranges", function()
		local server = fake.server({ ["textDocument/semanticTokens/full"] = function() return { data = Json.array({ 0, 0, 3, 0, 0 }) } end },
			{ capabilities = { semanticTokensProvider = { full = true, legend = legend } } })
		local client = Client.new({ id = "test", spawn = function() return server end,
			command = function() return { argv = { "fake" } } end })
		client:open("file:///test.py", "python", "abc")
		for _ = 1, 3 do client:pump() end
		local received
		client:semanticTokens("file:///test.py", function(tokens) received = tokens end)
		for _ = 1, 3 do client:pump() end
		assert.equal("keyword", received[1].role)
		assert.equal("file:///test.py", server:last("textDocument/semanticTokens/full").params.textDocument.uri)
	end)
	it("silently offers a fallback when full tokens are unsupported", function()
		local client = Client.new({ id = "test", spawn = function() end, command = function() end })
		local err
		client:semanticTokens("file:///test.py", function(_, why) err = why end)
		assert.is_true(err.unsupported)
	end)
end)
