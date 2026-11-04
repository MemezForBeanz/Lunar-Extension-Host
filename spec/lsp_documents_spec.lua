-- core.lsp.Documents and Diagnostics: what the server is told, and the mapping
-- between editor byte columns and protocol positions.

local Documents = require("core.lsp.Documents")
local Diagnostics = require("core.lsp.Diagnostics")
local fake = require("spec.support.fake_lsp")

local URI = "file:///C:/work/a.lua"

local function open_set(debounce)
	local sent = {}
	local clock = fake.clock()
	local docs = Documents.new({
		clock = clock, debounce = debounce,
		notify = function(method, params) sent[#sent + 1] = { method = method, params = params } end,
	})
	return docs, sent, clock
end

describe("lsp positions", function()
	-- "a", e-acute (2 bytes), euro sign (3 bytes), an emoji (4 bytes, 2 UTF-16 units), "z"
	local line = "a\195\169\226\130\172\240\159\152\128z"

	it("counts UTF-16 units for a byte column", function()
		assert.are.equal(0, Documents.byteToCharacter(line, 0))
		assert.are.equal(1, Documents.byteToCharacter(line, 1))
		assert.are.equal(2, Documents.byteToCharacter(line, 3))
		assert.are.equal(3, Documents.byteToCharacter(line, 6))
		assert.are.equal(5, Documents.byteToCharacter(line, 10))
		assert.are.equal(6, Documents.byteToCharacter(line, 11))
		assert.are.equal(6, Documents.byteToCharacter(line, 99))
	end)

	it("finds the byte column for a UTF-16 character", function()
		assert.are.equal(0, Documents.characterToByte(line, 0))
		assert.are.equal(1, Documents.characterToByte(line, 1))
		assert.are.equal(3, Documents.characterToByte(line, 2))
		assert.are.equal(6, Documents.characterToByte(line, 3))
		assert.are.equal(10, Documents.characterToByte(line, 5))
		assert.are.equal(11, Documents.characterToByte(line, 6))
		assert.are.equal(11, Documents.characterToByte(line, 500))
	end)

	it("round-trips every character boundary", function()
		for _, bytes in ipairs({ 0, 1, 3, 6, 10, 11 }) do
			local character = Documents.byteToCharacter(line, bytes)
			assert.are.equal(bytes, Documents.characterToByte(line, character))
		end
	end)

	it("is the identity when the server agreed to utf-8", function()
		assert.are.equal(6, Documents.byteToCharacter(line, 6, "utf-8"))
		assert.are.equal(6, Documents.characterToByte(line, 6, "utf-8"))
		assert.are.equal(#line, Documents.characterToByte(line, 500, "utf-8"))
	end)

	it("maps positions against the open document's lines, CRLF or LF", function()
		local docs = open_set()
		docs:open(URI, "lua", "first\r\ncaf\195\169 = 1\r\nthird")
		assert.are.same({ line = 1, character = 4 }, docs:toPosition(URI, 1, 5))
		local line_no, byte = docs:fromPosition(URI, { line = 1, character = 4 })
		assert.are.equal(1, line_no)
		assert.are.equal(5, byte)
		assert.are.equal("caf\195\169 = 1", Documents.lineOf(docs:get(URI), 1))
		assert.are.equal("third", Documents.lineOf(docs:get(URI), 2))
		assert.are.equal("", Documents.lineOf(docs:get(URI), 9))
	end)
end)

describe("lsp Documents", function()
	it("opens with version 1 once a server is live", function()
		local docs, sent = open_set()
		docs:open(URI, "lua", "x = 1")
		assert.are.equal(0, #sent)
		docs:setLive(true)
		assert.are.equal("textDocument/didOpen", sent[1].method)
		assert.are.same({ uri = URI, languageId = "lua", version = 1, text = "x = 1" }, sent[1].params.textDocument)
		assert.are.equal(1, docs:count())
	end)

	it("debounces typing into one didChange with the final text", function()
		local docs, sent, clock = open_set(0.15)
		docs:setLive(true)
		docs:open(URI, "lua", "a")
		for _, text in ipairs({ "ab", "abc", "abcd" }) do
			docs:change(URI, text)
			clock.advance(0.05)
			docs:tick()
		end
		assert.are.equal(1, #sent)   -- only the didOpen so far
		clock.advance(0.2)
		docs:tick()
		assert.are.equal(2, #sent)
		assert.are.equal("textDocument/didChange", sent[2].method)
		assert.are.equal(2, sent[2].params.textDocument.version)
		assert.are.equal("abcd", sent[2].params.contentChanges[1].text)
		docs:tick()
		assert.are.equal(2, #sent)
	end)

	it("flushes a pending change at once when asked", function()
		local docs, sent = open_set(10)
		docs:setLive(true)
		docs:open(URI, "lua", "a")
		docs:change(URI, "b")
		docs:flush(URI)
		assert.are.equal("textDocument/didChange", sent[2].method)
		docs:flush(URI)
		assert.are.equal(2, #sent)
	end)

	it("sends nothing for a change that changes nothing", function()
		local docs, sent = open_set(0)
		docs:setLive(true)
		docs:open(URI, "lua", "same")
		docs:change(URI, "same")
		docs:tick()
		assert.are.equal(1, #sent)
	end)

	it("closes a document and forgets it", function()
		local docs, sent = open_set()
		docs:setLive(true)
		docs:open(URI, "lua", "a")
		assert.is_true(docs:close(URI))
		assert.are.equal("textDocument/didClose", sent[2].method)
		assert.are.equal(0, docs:count())
		assert.is_false(docs:close(URI))
	end)

	it("finds a document by any spelling of its URI", function()
		local docs = open_set()
		docs:open("file:///C:/Work/A.lua", "lua", "a")
		-- The key folds case only where the file system does.
		local other = package.config:sub(1, 1) == "\\" and "file:///c%3A/work/a.lua" or "file:///C:/Work/A.lua"
		assert.is_not_nil(docs:get(other))
	end)

	it("reopens every document with its current text for a restarted server", function()
		local docs, sent = open_set(10)
		docs:setLive(true)
		docs:open(URI, "lua", "old")
		docs:change(URI, "new")   -- not sent yet
		docs:setLive(false)
		docs:setLive(true)
		local reopen = sent[#sent]
		assert.are.equal("textDocument/didOpen", reopen.method)
		assert.are.equal("new", reopen.params.textDocument.text)
		assert.is_true(reopen.params.textDocument.version > 1)
		docs:tick()
		assert.are.equal("textDocument/didOpen", sent[#sent].method)   -- nothing stale follows
	end)
end)

describe("lsp Diagnostics", function()
	local function diag(line, message, severity)
		return {
			range = { start = { line = line, character = 2 }, ["end"] = { line = line, character = 7 } },
			message = message, severity = severity, source = "fake", code = "E1",
		}
	end

	it("stores a file's diagnostics in document order with named severities", function()
		local store = Diagnostics.new()
		store:set(URI, "lua", { diag(9, "later", 2), diag(1, "earlier", 1) })
		local list = store:forUri(URI)
		assert.are.equal("earlier", list[1].message)
		assert.are.equal("error", list[1].kind)
		assert.are.equal("warning", list[2].kind)
		assert.are.equal(7, list[1].end_character)
		assert.are.equal("E1", list[1].code)
	end)

	it("treats a missing severity as an error and tolerates missing ranges", function()
		local store = Diagnostics.new()
		store:set(URI, "lua", { { message = "no range" } })
		local entry = store:forUri(URI)[1]
		assert.are.equal("error", entry.kind)
		assert.are.equal(0, entry.line)
	end)

	it("replaces one server's entries without touching another's", function()
		local store = Diagnostics.new()
		store:set(URI, "lua", { diag(1, "from lua", 1) })
		store:set(URI, "lint", { diag(2, "from lint", 2) })
		store:set(URI, "lua", { diag(3, "lua again", 1) })
		local list = store:forUri(URI)
		assert.are.equal(2, #list)
		assert.are.equal("from lint", list[1].message)
		assert.are.equal("lua again", list[2].message)
	end)

	it("counts by severity and summarizes in words", function()
		local store = Diagnostics.new()
		assert.are.equal("No problems", Diagnostics.summary(store:counts()))
		store:set(URI, "lua", { diag(1, "a", 1), diag(2, "b", 1), diag(3, "c", 2), diag(4, "d", 4) })
		store:set("file:///C:/work/b.lua", "lua", { diag(1, "e", 3) })
		local counts = store:counts()
		assert.are.same({ error = 2, warning = 1, info = 1, hint = 1, total = 5, files = 2 }, counts)
		assert.are.equal("2 errors, 1 warning, 2 notes", Diagnostics.summary(counts))
	end)

	it("lists everything with errors first", function()
		local store = Diagnostics.new()
		store:set("file:///C:/work/b.lua", "lua", { diag(1, "warn b", 2) })
		store:set(URI, "lua", { diag(5, "warn a", 2), diag(9, "error a", 1) })
		local list = store:list()
		assert.are.equal("error a", list[1].message)
		assert.are.equal("warn a", list[2].message)
		assert.are.equal("warn b", list[3].message)
	end)

	it("clears on an empty publish and when a server goes away", function()
		local store = Diagnostics.new()
		store:set(URI, "lua", { diag(1, "a", 1) })
		store:set(URI, "lua", {})
		assert.are.equal(0, store:counts().total)
		store:set(URI, "lua", { diag(1, "a", 1) })
		store:set(URI, "c", { diag(1, "b", 1) })
		store:clearServer("lua")
		assert.are.equal(1, store:counts().total)
		assert.are.equal("c", store:forUri(URI)[1].server)
	end)

	it("tells listeners which file changed, until they unsubscribe", function()
		local store = Diagnostics.new()
		local seen = {}
		local stop = store:onChange(function(uri) seen[#seen + 1] = uri end)
		store:set(URI, "lua", { diag(1, "a", 1) })
		store:set(URI, "lua", {})
		store:set(URI, "lua", {})   -- already empty: no change
		stop()
		store:set(URI, "lua", { diag(1, "a", 1) })
		assert.are.same({ URI, URI }, seen)
	end)
end)
