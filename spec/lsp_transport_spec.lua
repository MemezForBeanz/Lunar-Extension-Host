-- core.lsp.Json, Uri and Transport: the bytes on the wire.

local Json = require("core.lsp.Json")
local Uri = require("core.lsp.Uri")
local Transport = require("core.lsp.Transport")
local fake = require("spec.support.fake_lsp")

describe("lsp Json", function()
	it("encodes an empty marked array as [] and an empty table as {}", function()
		assert.are.equal('{"a":[],"b":{}}', Json.encode({ a = Json.array({}), b = {} }))
	end)

	it("encodes sequences as arrays and keeps integers integral", function()
		assert.are.equal('{"list":[1,2,3],"n":7,"version":120000000}',
			Json.encode({ list = { 1, 2, 3 }, n = 7, version = 120000000 }))
		assert.are.equal("0.5", Json.encode(0.5))
	end)

	it("escapes quotes, backslashes and control characters", function()
		assert.are.equal('"a\\"b\\\\c\\n\\t\\u0001"', Json.encode('a"b\\c\n\t\1'))
	end)

	it("writes null for Json.null and sorts keys", function()
		assert.are.equal('{"a":null,"b":true,"c":"x"}', Json.encode({ c = "x", a = Json.null, b = true }))
	end)

	it("refuses values JSON cannot hold, with a reason", function()
		local text, err = Json.encode({ fn = function() end })
		assert.is_nil(text)
		assert.matches("cannot represent a function", err)
		assert.is_nil((Json.encode({ [1] = "a", x = "b" })))
	end)

	it("round-trips through decode, null included", function()
		local value = assert(Json.decode(Json.encode({ items = Json.array({}), text = "héllo \240\159\152\128", none = Json.null })))
		assert.are.equal("héllo \240\159\152\128", value.text)
		assert.are.equal(Json.null, value.none)
		assert.is_true(Json.isNull(value.none))
		assert.is_true(Json.isNull(nil))
	end)

	it("reports invalid JSON instead of raising", function()
		local value, err = Json.decode("{not json")
		assert.is_nil(value)
		assert.is_string(err)
	end)
end)

describe("lsp Uri", function()
	it("turns Windows paths into file URIs and back", function()
		assert.are.equal("file:///C:/Work/my%20repo/a.lua", Uri.fromPath("c:\\Work\\my repo\\a.lua", true))
		assert.are.equal("C:\\Work\\my repo\\a.lua", Uri.toPath("file:///C:/Work/my%20repo/a.lua", true))
		assert.are.equal("C:\\Work\\a.lua", Uri.toPath("file:///c%3A/Work/a.lua", true))
	end)

	it("handles UNC shares", function()
		assert.are.equal("file://server/share/dir/a.c", Uri.fromPath("\\\\server\\share\\dir\\a.c", true))
		assert.are.equal("\\\\server\\share\\dir\\a.c", Uri.toPath("file://server/share/dir/a.c", true))
	end)

	it("handles POSIX paths", function()
		assert.are.equal("file:///home/me/a%23b.py", Uri.fromPath("/home/me/a#b.py", false))
		assert.are.equal("/home/me/a#b.py", Uri.toPath("file:///home/me/a%23b.py", false))
	end)

	it("gives every spelling of one Windows file the same key", function()
		assert.are.equal(Uri.key("file:///C:/Work/A.lua", true), Uri.key("file:///c%3A/work/a.lua", true))
		assert.are_not.equal(Uri.key("file:///home/A.lua", false), Uri.key("file:///home/a.lua", false))
	end)

	it("answers nil for something that is not a file URI", function()
		assert.is_nil(Uri.toPath("untitled:Untitled-1"))
		assert.is_nil(Uri.toPath(nil))
	end)
end)

describe("lsp Transport", function()
	local function connect(server)
		local got, closed = {}, {}
		local transport = Transport.new({
			process = server,
			on_message = function(body) got[#got + 1] = body end,
			on_stderr = function(text) got.stderr = (got.stderr or "") .. text end,
			on_close = function(reason, code) closed[#closed + 1] = { reason = reason, code = code } end,
		})
		return transport, got, closed
	end

	it("frames what it sends with the body's byte length", function()
		local written = {}
		local process = { write = function(_, data) written[#written + 1] = data; return true end }
		local transport = Transport.new({ process = process, on_message = function() end })
		assert.is_true(transport:send('{"t":"é"}'))
		assert.are.equal('Content-Length: 10\r\n\r\n{"t":"é"}', written[1])
		assert.are.equal(1, transport.sent)
	end)

	it("delivers a message that arrives whole", function()
		local server = fake.server()
		local transport, got = connect(server)
		server:raw(fake.frame('{"a":1}'))
		assert.is_true(transport:pump())
		assert.are.same({ '{"a":1}' }, got)
	end)

	it("reassembles a message that arrives one byte at a time", function()
		local server = fake.server(nil, { chunk = 1 })
		local transport, got = connect(server)
		local body = '{"method":"x","params":{"text":"' .. string.rep("y", 300) .. '"}}'
		server:raw(fake.frame(body))
		-- One pump drains everything waiting, however it is chunked.
		transport:pump()
		assert.are.same({ body }, got)
	end)

	it("delivers several messages from one read, in order", function()
		local server = fake.server()
		local transport, got = connect(server)
		server:raw(fake.frame("one") .. fake.frame("two") .. fake.frame("three"))
		transport:pump()
		assert.are.same({ "one", "two", "three" }, got)
		assert.are.equal(3, transport.received)
	end)

	it("keeps a partial message until the rest arrives", function()
		local server = fake.server()
		local transport, got = connect(server)
		local frame = fake.frame("0123456789")
		server:raw(frame:sub(1, 25))
		transport:pump()
		assert.are.same({}, got)
		server:raw(frame:sub(26))
		transport:pump()
		assert.are.same({ "0123456789" }, got)
	end)

	it("accepts extra headers and any header case", function()
		local server = fake.server()
		local transport, got = connect(server)
		server:raw("content-type: application/vscode-jsonrpc; charset=utf-8\r\ncontent-length: 2\r\n\r\nok")
		transport:pump()
		assert.are.same({ "ok" }, got)
	end)

	it("ends the connection on a header without Content-Length", function()
		local server = fake.server()
		local transport, got, closed = connect(server)
		server:raw("Content-Type: text/plain\r\n\r\nhello")
		assert.is_false(transport:pump())
		assert.are.same({}, got)
		assert.matches("Content%-Length", closed[1].reason)
		assert.is_false(transport:isOpen())
		assert.is_true(server.closed)
	end)

	it("ends the connection on output that is not a protocol stream", function()
		local server = fake.server()
		local transport, _, closed = connect(server)
		server:raw(string.rep("Usage: server [options]\n", 600))
		assert.is_false(transport:pump())
		assert.matches("not a protocol header", closed[1].reason)
	end)

	it("refuses a message larger than the limit", function()
		local server = fake.server()
		local transport, _, closed = connect(server)
		server:raw("Content-Length: " .. (Transport.MAX_BODY + 1) .. "\r\n\r\n")
		assert.is_false(transport:pump())
		assert.matches("byte message", closed[1].reason)
	end)

	it("reports the exit code when the server goes away, once", function()
		local server = fake.server()
		local transport, got, closed = connect(server)
		server:raw(fake.frame("last words"))
		server:die(3)
		transport:pump()   -- delivers what was written before the exit
		assert.are.same({ "last words" }, got)
		assert.is_false(transport:pump())
		assert.is_false(transport:pump())
		assert.are.equal(1, #closed)
		assert.are.equal(3, closed[1].code)
	end)

	it("passes stderr on without treating it as protocol", function()
		local server = fake.server()
		local transport, got = connect(server)
		server.err = "warning: something\n"
		server:raw(fake.frame("fine"))
		transport:pump()
		assert.are.equal("warning: something\n", got.stderr)
		assert.are.same({ "fine" }, { got[1] })
	end)

	it("refuses to send once closed, and close is silent", function()
		local server = fake.server()
		local transport, _, closed = connect(server)
		transport:close()
		assert.is_true(server.closed)
		assert.are.equal(0, #closed)
		local ok, err = transport:send("x")
		assert.is_nil(ok)
		assert.matches("closed", err)
		assert.is_false(transport:pump())
	end)

	it("reports a server that is not reading as backlog", function()
		local server = fake.server()
		local transport = connect(server)
		server.stalled = true
		transport:send(string.rep("x", 1000))
		assert.is_true(transport:backlog() > 1000)
	end)
end)
