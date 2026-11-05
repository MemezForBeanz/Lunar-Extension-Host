-- core.lsp.Client against a fake server: the handshake, the documents, the
-- requests the UI makes, and what happens when the server misbehaves.

local Json = require("core.lsp.Json")
local Client = require("core.lsp.Client")
local fake = require("spec.support.fake_lsp")

local URI = "file:///C:/work/proj/a.lua"

-- A client whose every start hands out the next server from `servers` (or a
-- fresh default one), so restarts can be observed.
local function setup(opts)
	opts = opts or {}
	local clock = fake.clock()
	local started, states, logs, published = {}, {}, {}, {}
	local queue = opts.servers or {}
	local client = Client.new({
		id = "lua", name = "Lua",
		root = opts.root or "C:\\work\\proj",
		settings = opts.settings,
		init_options = opts.init_options,
		clock = clock,
		command = opts.command or function() return { argv = { "fake-server", "--stdio" } } end,
		spawn = opts.spawn or function(spawn_opts)
			local server = table.remove(queue, 1) or fake.server(opts.handlers, opts.server_opts)
			server.spawn_opts = spawn_opts
			started[#started + 1] = server
			return server
		end,
		on_state = function(state, detail) states[#states + 1] = { state = state, detail = detail } end,
		on_log = function(level, message) logs[#logs + 1] = level .. ": " .. message end,
		on_diagnostics = function(uri, list) published[#published + 1] = { uri = uri, list = list } end,
	})
	local function pump(times)
		for _ = 1, times or 3 do client:pump() end
	end
	local function state_names()
		local out = {}
		for _, s in ipairs(states) do out[#out + 1] = s.state end
		return out
	end
	return client, { clock = clock, started = started, states = states, logs = logs,
		published = published, pump = pump, names = state_names }
end

describe("lsp Client startup", function()
	it("initializes, announces itself, and reaches running", function()
		local client, t = setup({ settings = { Lua = { diagnostics = { globals = { "vim" } } } } })
		assert.is_true(client:start())
		assert.are.equal("starting", client.state)
		t.pump()
		assert.are.equal("running", client.state)
		local server = t.started[1]
		assert.is_true(server.spawn_opts.stdin)
		assert.are.same({ "fake-server", "--stdio" }, server.spawn_opts.argv)
		assert.are.equal("C:\\work\\proj", server.spawn_opts.cwd)

		local init = server:last("initialize").params
		assert.are.equal("file:///C:/work/proj", init.rootUri)
		assert.are.equal("file:///C:/work/proj", init.workspaceFolders[1].uri)
		assert.are.same({ "utf-8", "utf-16" }, init.capabilities.general.positionEncodings)
		assert.is_false(init.capabilities.textDocument.completion.completionItem.snippetSupport)
		assert.are.same({ "initialize", "initialized", "workspace/didChangeConfiguration" }, server:methods())
		assert.are.same({ "vim" },
			server:last("workspace/didChangeConfiguration").params.settings.Lua.diagnostics.globals)
		assert.are.equal("fake", client.server_info.name)
	end)

	it("opens documents queued before the server was ready", function()
		local client, t = setup()
		client:open(URI, "lua", "local x = 1")
		assert.are.equal("starting", client.state)   -- open started it
		assert.are.equal(0, t.started[1]:count("textDocument/didOpen"))
		t.pump()
		local opened = t.started[1]:last("textDocument/didOpen").params.textDocument
		assert.are.equal("local x = 1", opened.text)
		assert.are.equal("lua", opened.languageId)
	end)

	it("gates features on what the server says it provides", function()
		local client, t = setup({ server_opts = { capabilities = { hoverProvider = true, completionProvider = Json.null } } })
		assert.is_false(client:supports("hover"))   -- not running yet
		client:start()
		t.pump()
		assert.is_true(client:supports("hover"))
		assert.is_false(client:supports("completion"))
		assert.is_false(client:supports("definition"))
		local err
		assert.is_nil(client:definition(URI, 0, 0, function(_, e) err = e end))
		assert.is_true(err.unsupported)
		assert.are.equal(0, t.started[1]:count("textDocument/definition"))
	end)

	it("uses utf-8 positions when the server chooses them", function()
		local client, t = setup({ server_opts = { capabilities = { hoverProvider = true, positionEncoding = "utf-8" } } })
		client:open(URI, "lua", "caf\195\169 = 1")
		t.pump()
		client:hover(URI, 0, 5, function() end)
		assert.are.equal(5, t.started[1]:last("textDocument/hover").params.position.character)
	end)

	it("says plainly when there is no server to run", function()
		local client, t = setup({ command = function() return nil, "clangd was not found on this computer." end })
		local ok, err = client:start()
		assert.is_nil(ok)
		assert.are.equal("clangd was not found on this computer.", err)
		assert.are.equal("unavailable", client.state)
		assert.are.equal("clangd was not found on this computer.", client.detail)
		assert.are.equal(0, #t.started)
		assert.is_false(client:isActive())
	end)

	it("reports a spawn failure as failed, without a restart loop", function()
		local client = setup({ spawn = function() return nil, "CreateProcess failed (2)" end })
		local ok, err = client:start()
		assert.is_nil(ok)
		assert.matches("could not start fake%-server", err)
		assert.are.equal("failed", client.state)
		assert.is_false(client:isActive())
	end)
end)

describe("lsp Client requests", function()
	local function running(handlers, server_opts)
		local client, t = setup({ handlers = handlers, server_opts = server_opts })
		client:open(URI, "lua", "local caf\195\169 = require('x')\nprint(caf\195\169)\n")
		t.pump()
		return client, t, t.started[1]
	end

	it("asks for hover at a UTF-16 position and returns the result", function()
		local client, t, server = running({
			["textDocument/hover"] = function() return { contents = { kind = "markdown", value = "**local** x" } } end,
		})
		local hover
		client:hover(URI, 1, 11, function(result) hover = result end)   -- byte 11 is after the e-acute
		t.pump()
		assert.are.equal("**local** x", hover.contents.value)
		assert.are.same({ line = 1, character = 10 }, server:last("textDocument/hover").params.position)
	end)

	it("sends a pending edit before the request that depends on it", function()
		local client, t, server = running({ ["textDocument/hover"] = function() return Json.null end })
		client:change(URI, "local y = 2\n")
		client:hover(URI, 0, 6, function() end)
		t.pump()
		local methods = server:methods()
		assert.are.equal("textDocument/didChange", methods[#methods - 1])
		assert.are.equal("textDocument/hover", methods[#methods])
	end)

	it("returns completion items from a list or a bare array", function()
		local client, t, server = running({
			["textDocument/completion"] = function(params)
				if params.context.triggerKind == 2 then
					return { isIncomplete = true, items = { { label = "insert" }, { label = "ipairs" } } }
				end
				return { { label = "print" } }
			end,
		})
		local items, incomplete
		client:completion(URI, 1, 2, ".", function(list, _, more) items, incomplete = list, more end)
		t.pump()
		assert.are.equal(2, #items)
		assert.is_true(incomplete)
		assert.are.equal(".", server:last("textDocument/completion").params.context.triggerCharacter)
		client:completion(URI, 1, 2, nil, function(list, _, more) items, incomplete = list, more end)
		t.pump()
		assert.are.equal("print", items[1].label)
		assert.is_false(incomplete)
		assert.are.same({ ".", ":" }, client:completionTriggers())
	end)

	it("normalizes definition results: one Location, a list, or LocationLinks", function()
		local range = { start = { line = 3, character = 6 }, ["end"] = { line = 3, character = 9 } }
		local answers = {
			{ uri = "file:///C:/work/proj/b.lua", range = range },
			{ { uri = "file:///C:/work/proj/b.lua", range = range }, { uri = "file:///C:/work/proj/c.lua", range = range } },
			{ { targetUri = "file:///C:/work/proj/d.lua", targetRange = range, targetSelectionRange = range } },
			Json.null,
		}
		local client, t = running({
			["textDocument/definition"] = function() return table.remove(answers, 1) end,
		})
		local got = {}
		for i = 1, 4 do
			client:definition(URI, 0, 6, function(locations) got[i] = locations end)
			t.pump()
		end
		assert.are.equal(1, #got[1])
		assert.are.equal("file:///C:/work/proj/b.lua", got[1][1].uri)
		assert.are.equal(2, #got[2])
		assert.are.equal("file:///C:/work/proj/d.lua", got[3][1].uri)
		assert.are.equal(3, got[3][1].range.start.line)
		assert.are.same({}, got[4])
	end)

	it("routes published diagnostics to the host", function()
		local _, t, server = running()
		server:notify("textDocument/publishDiagnostics", { uri = URI, diagnostics = {
			{ range = { start = { line = 0, character = 6 }, ["end"] = { line = 0, character = 10 } },
				severity = 2, message = "unused local" },
		} })
		t.pump()
		assert.are.equal(URI, t.published[1].uri)
		assert.are.equal("unused local", t.published[1].list[1].message)
	end)

	it("answers the server's own requests truthfully", function()
		local client, t = setup({ settings = { Lua = { runtime = { version = "LuaJIT" } } } })
		client:start()
		t.pump()
		local server = t.started[1]
		server:request(100, "workspace/configuration", { items = { { section = "Lua.runtime" }, { section = "nope" } } })
		server:request(101, "client/registerCapability", { registrations = {} })
		server:request(102, "workspace/applyEdit", { edit = {} })
		server:request(103, "window/workDoneProgress/create", { token = "t" })
		t.pump()
		assert.are.equal("LuaJIT", server.replies[100].result[1].version)
		assert.are.equal(Json.null, server.replies[100].result[2])
		assert.are.equal(Json.null, server.replies[101].result)
		assert.is_false(server.replies[102].result.applied)
		assert.is_nil(server.replies[103].error)
	end)

	it("passes server log messages on with a level", function()
		local _, t, server = running()
		server:notify("window/logMessage", { type = 2, message = "indexing is slow" })
		t.pump()
		assert.are.equal("warning: indexing is slow", t.logs[#t.logs])
	end)

	it("tells the server when a document is saved and closed", function()
		local client, t, server = running()
		client:saved(URI)
		client:close(URI)
		t.pump()
		assert.are.equal(1, server:count("textDocument/didSave"))
		assert.are.equal(1, server:count("textDocument/didClose"))
	end)
end)

describe("lsp Client failure handling", function()
	it("restarts a crashed server after 1 s, 5 s and 30 s, then stops trying", function()
		local client, t = setup()
		client:open(URI, "lua", "x = 1")
		t.pump()
		for attempt, delay in ipairs({ 1, 5, 30 }) do
			t.started[attempt].err = "panic: something broke\n"
			t.started[attempt]:die(101)
			t.pump()
			assert.are.equal("restarting", client.state)
			assert.matches("exit code 101", client.detail)
			assert.matches("panic: something broke", client.detail)
			t.clock.advance(delay - 0.5)
			t.pump()
			assert.are.equal(attempt, #t.started)       -- not yet
			t.clock.advance(1)
			t.pump()
			assert.are.equal(attempt + 1, #t.started)   -- restarted
			assert.are.equal("running", client.state)
			-- The restarted server gets the document again.
			assert.are.equal("x = 1", t.started[attempt + 1]:last("textDocument/didOpen").params.textDocument.text)
		end
		t.started[4]:die(101)
		t.pump()
		assert.are.equal("failed", client.state)
		t.clock.advance(600)
		t.pump()
		assert.are.equal(4, #t.started)
		assert.is_false(client:isActive())
		-- A person can still ask for another go.
		assert.is_true(client:start())
		t.pump()
		assert.are.equal("running", client.state)
	end)

	it("forgives earlier crashes once a server has been stable", function()
		local client, t = setup()
		client:start()
		t.pump()
		for _ = 1, 5 do
			t.clock.advance(Client.STABLE_AFTER + 1)
			t.started[#t.started]:die(1)
			t.pump()
			assert.are.equal("restarting", client.state)
			t.clock.advance(1.5)   -- always the first backoff step
			t.pump()
			assert.are.equal("running", client.state)
		end
	end)

	it("fails waiting requests when the server dies", function()
		local client, t = setup({ handlers = { ["textDocument/hover"] = function() return fake.NO_REPLY end } })
		client:open(URI, "lua", "x")
		t.pump()
		local err
		client:hover(URI, 0, 0, function(_, e) err = e end)
		t.started[1]:die(1)
		t.pump()
		assert.is_true(err.closed)
	end)

	it("treats a failed initialize as a crash", function()
		local client, t = setup({ handlers = {
			initialize = function() return nil, { code = -32603, message = "bad workspace" } end,
		} })
		client:start()
		t.pump()
		assert.are.equal("restarting", client.state)
		assert.matches("initialize failed: bad workspace", client.detail)
	end)

	it("ends a server that has stopped reading its input", function()
		local client, t = setup()
		client:open(URI, "lua", "x")
		t.pump()
		local server = t.started[1]
		server.stalled = true
		client:change(URI, "y")
		t.clock.advance(1)
		t.pump()
		assert.are.equal("running", client.state)   -- a backlog alone is not a hang
		t.clock.advance(Client.STALL_AFTER + 1)
		t.pump()
		assert.are.equal("restarting", client.state)
		assert.matches("stopped reading", client.detail)
		assert.is_true(server.closed)
	end)

	it("ends a server whose output is not a protocol stream", function()
		local client, t = setup()
		client:start()
		t.started[1]:raw("Content-Type: nonsense\r\n\r\n")
		t.pump()
		assert.are.equal("restarting", client.state)
	end)
end)

describe("lsp Client shutdown", function()
	it("stops politely: shutdown, then exit, then the process is released", function()
		local client, t = setup()
		client:open(URI, "lua", "x")
		t.pump()
		local server = t.started[1]
		client:stop()
		assert.are.equal("stopped", client.state)
		t.pump()
		assert.are.same({ "shutdown", "exit" }, { server:methods()[#server:methods() - 1], server:methods()[#server:methods()] })
		assert.is_true(server.closed)
		assert.is_false(client:isActive())
		-- The document is kept for the next start.
		client:start()
		t.pump()
		assert.are.equal("x", t.started[2]:last("textDocument/didOpen").params.textDocument.text)
	end)

	it("ends a server that ignores shutdown once the grace period is over", function()
		local client, t = setup({ handlers = { shutdown = function() return fake.NO_REPLY end } })
		client:start()
		t.pump()
		local server = t.started[1]
		client:stop()
		t.pump()
		assert.is_false(server.closed)
		t.clock.advance(Client.SHUTDOWN_GRACE + 0.1)
		t.pump()
		assert.is_true(server.closed)
		assert.is_false(client:isActive())
	end)

	it("kills at once on unload, with no restart", function()
		local client, t = setup()
		client:start()
		t.pump()
		client:kill()
		assert.is_true(t.started[1].closed)
		assert.are.equal("stopped", client.state)
		t.clock.advance(100)
		t.pump()
		assert.are.equal(1, #t.started)
	end)

	it("stops an idle server after five minutes with nothing open", function()
		local client, t = setup()
		client:open(URI, "lua", "x")
		t.pump()
		t.clock.advance(Client.IDLE_STOP + 10)
		t.pump()
		assert.are.equal("running", client.state)   -- a document is open
		client:close(URI)
		t.clock.advance(Client.IDLE_STOP - 5)
		t.pump()
		assert.are.equal("running", client.state)
		t.clock.advance(10)
		t.pump()
		assert.are.equal("stopped", client.state)
		assert.are.equal("idle", client.detail)
		-- Opening a file again brings it back.
		client:open(URI, "lua", "x")
		t.pump()
		assert.are.equal("running", client.state)
	end)
end)
