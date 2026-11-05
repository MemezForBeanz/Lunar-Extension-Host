--- One running language server: start, `initialize`, the open documents, the
-- requests the UI makes of it, and what happens when it dies.
--
-- **States.** `stopped` → `starting` → `running`; a server that exits on its own
-- goes to `restarting` and is started again after 1 s, 5 s, then 30 s. A fourth
-- failure in a row leaves it `failed`, and it stays that way until `start` is
-- called by hand: a server that cannot stay up should not be spawned in a loop.
-- A server that has run for a minute has earned a fresh set of attempts.
--
-- **Nothing here blocks.** `pump` is called from a timer; it moves bytes, expires
-- requests, sends debounced edits and notices a server that has stopped reading
-- its input (it is ended and restarted like any other failure).
--
-- **Capabilities gate the features.** `supports("hover")` is false until the
-- server has said it provides hover, so the UI can leave the feature off instead
-- of sending requests that will be refused.
--
-- @classmod core.lsp.Client
local Json = require("core.lsp.Json")
local Uri = require("core.lsp.Uri")
local Transport = require("core.lsp.Transport")
local Rpc = require("core.lsp.Rpc")
local Documents = require("core.lsp.Documents")

local Client = {}
Client.__index = Client

-- Seconds to wait before each restart attempt. A plain comment: LDoc refuses a
-- documented table with array entries.
Client.BACKOFF = { 1, 5, 30 }
--- Seconds a server must stay up before a later crash counts as its first.
Client.STABLE_AFTER = 60
--- Seconds with every document closed before the server is stopped.
Client.IDLE_STOP = 300
--- Seconds a server may leave its input unread before it is treated as hung.
Client.STALL_AFTER = 20
--- Seconds allowed for `initialize`. Servers index on startup; be generous.
Client.INIT_TIMEOUT = 60
--- Seconds allowed for a polite shutdown before the process is ended.
Client.SHUTDOWN_GRACE = 2

--- What each feature is called in the server's capabilities.
Client.FEATURES = {
	hover = "hoverProvider",
	completion = "completionProvider",
	definition = "definitionProvider",
	symbols = "documentSymbolProvider",
	references = "referencesProvider",
}

local function default_clock()
	local ok, socket = pcall(require, "socket")
	if ok and socket.gettime then return socket.gettime end
	return os.time
end

--- What this client tells a server it can do. Kept small and true: every entry
-- here is something the host actually handles.
function Client.capabilities()
	return {
		general = { positionEncodings = Json.array({ "utf-8", "utf-16" }) },
		workspace = { configuration = true, workspaceFolders = true },
		window = { workDoneProgress = true },
		textDocument = {
			synchronization = { didSave = true, dynamicRegistration = false },
			publishDiagnostics = { relatedInformation = false, versionSupport = false },
			hover = { contentFormat = Json.array({ "markdown", "plaintext" }) },
			completion = {
				contextSupport = true,
				completionItem = {
					snippetSupport = false,
					documentationFormat = Json.array({ "markdown", "plaintext" }),
				},
			},
			definition = { linkSupport = true },
			documentSymbol = { hierarchicalDocumentSymbolSupport = true },
		},
	}
end

--- Create a client. It does not start until `start` or the first `open`.
--
-- @tparam table opts
-- @tparam string opts.id the server's id (`"lua"`, `"c"`, ...)
-- @tparam[opt] string opts.name what to call it in messages
-- @tparam function opts.spawn `fn{ argv, cwd, env, stdin = true } -> process | nil, err`
-- @tparam function opts.command `fn(root) -> { argv, cwd, env } | nil, reason`:
--   resolved on every start, so a server installed while Lunar runs is found
-- @tparam[opt] string opts.root the workspace folder
-- @tparam[opt] table opts.settings sent as `workspace/didChangeConfiguration` and
--   answered to `workspace/configuration`
-- @tparam[opt] table opts.init_options `initializationOptions`
-- @tparam[opt] function opts.clock seconds
-- @tparam[opt] function opts.on_state `fn(state, detail)` on every state change
-- @tparam[opt] function opts.on_diagnostics `fn(uri, diagnostics, version)`
-- @tparam[opt] function opts.on_log `fn(level, message)`; level is `"error"`,
--   `"warning"`, `"info"` or `"log"`
-- @tparam[opt] function opts.on_progress `fn(token, value)` for `$/progress`
function Client.new(opts)
	assert(type(opts) == "table", "Client.new: opts table required")
	assert(type(opts.id) == "string" and opts.id ~= "", "Client.new: opts.id is required")
	assert(type(opts.spawn) == "function", "Client.new: opts.spawn is required")
	assert(type(opts.command) == "function", "Client.new: opts.command is required")
	local self = setmetatable({
		id = opts.id,
		name = opts.name or opts.id,
		root = opts.root,
		state = "stopped",
		detail = nil,
		server = {},           -- the server's capabilities, once initialized
		server_info = nil,
		_spawn = opts.spawn,
		_command = opts.command,
		_settings = opts.settings,
		_init_options = opts.init_options,
		_clock = opts.clock or default_clock(),
		_on_state = opts.on_state,
		_on_diagnostics = opts.on_diagnostics,
		_on_log = opts.on_log,
		_on_progress = opts.on_progress,
		_failures = 0,
		_stderr_tail = "",
	}, Client)
	self.documents = Documents.new({
		clock = self._clock,
		notify = function(method, params)
			if self._rpc and self.state == "running" then self._rpc:notify(method, params) end
		end,
	})
	return self
end

function Client:_log(level, message)
	if self._on_log then pcall(self._on_log, level, message) end
end

function Client:_setState(state, detail)
	if self.state == state and self.detail == detail then return end
	self.state, self.detail = state, detail
	if self._on_state then pcall(self._on_state, state, detail) end
end

--- Is a feature available? False until the server is running and has said so.
-- @tparam string feature a key of `Client.FEATURES`
function Client:supports(feature)
	if self.state ~= "running" then return false end
	local value = self.server[Client.FEATURES[feature] or feature]
	return value ~= nil and value ~= false and value ~= Json.null
end

--- Characters that should open completion as they are typed.
function Client:completionTriggers()
	local provider = self.server.completionProvider
	local list = type(provider) == "table" and provider.triggerCharacters
	return type(list) == "table" and list or {}
end

-- ---------------------------------------------------------------------------
-- Starting
-- ---------------------------------------------------------------------------

function Client:_settingsSection(section)
	local value = self._settings
	if type(value) ~= "table" then return Json.null end
	if type(section) ~= "string" or section == "" then return value end
	for part in section:gmatch("[^.]+") do
		if type(value) ~= "table" then return Json.null end
		value = value[part]
	end
	if value == nil then return Json.null end
	return value
end

function Client:_wire(rpc)
	rpc:onNotification("textDocument/publishDiagnostics", function(params)
		if type(params) ~= "table" or type(params.uri) ~= "string" then return end
		local list = type(params.diagnostics) == "table" and params.diagnostics or {}
		if self._on_diagnostics then self._on_diagnostics(params.uri, list, tonumber(params.version)) end
	end)
	local levels = { "error", "warning", "info", "log" }
	local function message(params)
		if type(params) ~= "table" then return end
		self:_log(levels[tonumber(params.type) or 4] or "log", tostring(params.message or ""))
	end
	rpc:onNotification("window/logMessage", message)
	rpc:onNotification("window/showMessage", message)
	rpc:onNotification("$/progress", function(params)
		if type(params) == "table" and self._on_progress then
			self._on_progress(params.token, params.value)
		end
	end)

	-- Requests a server makes of the client. Each is answered truthfully: the
	-- settings it asks for, and "no" to the things this host does not do.
	rpc:onRequest("workspace/configuration", function(params)
		local out = Json.array({})
		for _, item in ipairs(type(params) == "table" and type(params.items) == "table" and params.items or {}) do
			out[#out + 1] = self:_settingsSection(type(item) == "table" and item.section or nil)
		end
		return out
	end)
	rpc:onRequest("workspace/workspaceFolders", function()
		if not self.root then return Json.null end
		return Json.array({ { uri = Uri.fromPath(self.root), name = Uri.basename(Uri.fromPath(self.root)) } })
	end)
	rpc:onRequest("client/registerCapability", function() return Json.null end)
	rpc:onRequest("client/unregisterCapability", function() return Json.null end)
	rpc:onRequest("window/workDoneProgress/create", function() return Json.null end)
	rpc:onRequest("window/showMessageRequest", function(params)
		message(params)
		return Json.null
	end)
	rpc:onRequest("workspace/applyEdit", function()
		return { applied = false, failureReason = "Lunar does not apply workspace edits" }
	end)
end

--- Start the server. Safe to call in any state; a running server is left alone.
-- @treturn[1] boolean true once the process is up (initialization continues)
-- @treturn[2] nil
-- @treturn[2] string why it could not be started
function Client:start()
	if self.state == "starting" or self.state == "running" then return true end
	self._restart_at = nil
	local command, reason = self._command(self.root)
	if type(command) ~= "table" or type(command.argv) ~= "table" or not command.argv[1] then
		reason = reason or (self.name .. " has no command to run")
		self:_setState("unavailable", reason)
		return nil, reason
	end

	local process, err = self._spawn({
		argv = command.argv, cwd = command.cwd or self.root, env = command.env, stdin = true,
	})
	if not process then
		err = "could not start " .. tostring(command.argv[1]) .. ": " .. tostring(err)
		self:_setState("failed", err)
		return nil, err
	end

	self._stderr_tail = ""
	self._generation = (self._generation or 0) + 1
	local generation = self._generation
	-- The pair is bound to each other, not to the client: a server being shut
	-- down has left `self._rpc`, and its reply to `shutdown` still has to arrive.
	local transport
	local rpc = Rpc.new({
		send = function(text) return transport:send(text) end,
		clock = self._clock,
		on_error = function(message) self:_log("warning", message) end,
	})
	transport = Transport.new({
		process = process,
		on_message = function(body) rpc:handle(body) end,
		on_stderr = function(text)
			self._stderr_tail = (self._stderr_tail .. text):sub(-2000)
		end,
		on_close = function(why, code)
			if self._generation == generation then self:_lost(why, code) end
		end,
	})
	self._transport, self._rpc = transport, rpc
	self:_wire(rpc)
	self.server, self.server_info = {}, nil
	self._started_at = self._clock()
	self._stall_since = nil
	self:_setState("starting")

	local root_uri = self.root and Uri.fromPath(self.root) or Json.null
	rpc:request("initialize", {
		processId = (type(LUNAR_PID) == "number" and LUNAR_PID) or Json.null,
		clientInfo = { name = "Lunar Extension Host" },
		rootUri = root_uri,
		rootPath = self.root or Json.null,
		workspaceFolders = self.root
			and Json.array({ { uri = root_uri, name = Uri.basename(root_uri) } }) or Json.null,
		capabilities = Client.capabilities(),
		initializationOptions = self._init_options,
	}, function(result, init_err)
		if self._generation ~= generation or self.state ~= "starting" then return end
		if not result then
			return self:_lost("initialize failed: " .. tostring(init_err and init_err.message), nil)
		end
		self.server = type(result.capabilities) == "table" and result.capabilities or {}
		self.server_info = type(result.serverInfo) == "table" and result.serverInfo or nil
		self.documents:setEncoding(self.server.positionEncoding == "utf-8" and "utf-8" or "utf-16")
		rpc:notify("initialized", {})
		if self._settings ~= nil then
			rpc:notify("workspace/didChangeConfiguration", { settings = self._settings })
		end
		self:_setState("running")
		self.documents:setLive(true)
		self._idle_since = self.documents:count() == 0 and self._clock() or nil
	end, { timeout = Client.INIT_TIMEOUT })
	return true
end

-- The server went away without being asked to.
function Client:_lost(why, code)
	local transport, rpc = self._transport, self._rpc
	self._transport, self._rpc = nil, nil
	self._generation = (self._generation or 0) + 1
	if transport then transport:close() end
	self.documents:setLive(false)
	if rpc then rpc:failAll(why or "the server stopped") end

	local now = self._clock()
	if self._started_at and now - self._started_at >= Client.STABLE_AFTER then self._failures = 0 end
	self._failures = self._failures + 1

	local detail = tostring(why or "the server stopped")
	if code ~= nil then detail = detail .. " (exit code " .. tostring(code) .. ")" end
	local tail = self._stderr_tail:gsub("%s+$", "")
	local last_line = tail:match("([^\r\n]+)$")
	if last_line then detail = detail .. ": " .. last_line end
	self:_log("error", self.name .. ": " .. detail)

	local delay = Client.BACKOFF[self._failures]
	if not delay then
		self:_setState("failed", detail)
		return
	end
	self._restart_at = now + delay
	self:_setState("restarting", detail)
end

-- ---------------------------------------------------------------------------
-- Stopping
-- ---------------------------------------------------------------------------

--- Stop the server: a polite `shutdown` and `exit`, then the process is ended
-- if it has not gone within the grace period. Open documents are kept, so a
-- later `start` reopens them.
-- @tparam[opt] string reason shown as the state's detail
function Client:stop(reason)
	self._restart_at = nil
	local transport, rpc = self._transport, self._rpc
	if not transport then
		if self.state ~= "stopped" then self:_setState("stopped", reason) end
		return
	end
	self._generation = (self._generation or 0) + 1   -- on_close is no longer news
	self._transport, self._rpc = nil, nil
	self.documents:setLive(false)
	rpc:failAll(reason or "the server was stopped")
	self:_setState("stopped", reason)

	if not transport:isOpen() then return end
	-- The reply does not matter; what matters is that `exit` follows `shutdown`.
	local sent = rpc:request("shutdown", nil, function()
		rpc:notify("exit")
	end, { timeout = Client.SHUTDOWN_GRACE })
	if not sent then
		transport:close()
		return
	end
	self._closing = self._closing or {}
	table.insert(self._closing, { transport = transport, rpc = rpc, deadline = self._clock() + Client.SHUTDOWN_GRACE })
end

--- End the server now, with no goodbye. For unload and application exit.
function Client:kill()
	self._restart_at = nil
	self._generation = (self._generation or 0) + 1
	local transport, rpc = self._transport, self._rpc
	self._transport, self._rpc = nil, nil
	self.documents:setLive(false)
	if rpc then rpc:failAll("the server was stopped") end
	if transport then transport:close() end
	for _, closing in ipairs(self._closing or {}) do closing.transport:close() end
	self._closing = nil
	if self.state ~= "stopped" then self:_setState("stopped") end
end

--- Is there anything for `pump` to do? False for a client at rest.
function Client:isActive()
	return self._transport ~= nil or self._restart_at ~= nil or (self._closing ~= nil and #self._closing > 0)
end

-- ---------------------------------------------------------------------------
-- The pump
-- ---------------------------------------------------------------------------

--- Move the client forward: read, dispatch, time out, restart, idle-stop.
-- @treturn boolean `isActive()`
function Client:pump()
	local now = self._clock()

	-- Servers on their way out: read until they exit, then make sure.
	if self._closing then
		for i = #self._closing, 1, -1 do
			local closing = self._closing[i]
			local alive = closing.transport:pump()
			closing.rpc:tick()
			if not alive or now >= closing.deadline then
				closing.transport:close()
				table.remove(self._closing, i)
			end
		end
		if #self._closing == 0 then self._closing = nil end
	end

	if self._restart_at and now >= self._restart_at then
		self._restart_at = nil
		self:start()
	end

	local transport, rpc = self._transport, self._rpc
	if not transport then return self:isActive() end

	transport:pump()
	if self._transport ~= transport then return self:isActive() end   -- it was lost in the pump
	rpc:tick()
	if self._transport ~= transport then return self:isActive() end

	if self.state == "running" then
		self.documents:tick()
		if self.documents:count() == 0 then
			self._idle_since = self._idle_since or now
			if now - self._idle_since >= Client.IDLE_STOP then
				self:stop("idle")
				return self:isActive()
			end
		else
			self._idle_since = nil
		end
	end

	-- A server that has stopped reading: its input backs up and never drains.
	if transport:backlog() > 0 then
		self._stall_since = self._stall_since or now
		if now - self._stall_since >= Client.STALL_AFTER then
			self:_lost("the server stopped reading its input", nil)
		end
	else
		self._stall_since = nil
	end
	return self:isActive()
end

-- ---------------------------------------------------------------------------
-- Documents
-- ---------------------------------------------------------------------------

--- Open a document with the server, starting it if need be.
function Client:open(uri, language_id, text)
	self._idle_since = nil
	local doc = self.documents:open(uri, language_id, text)
	if self.state == "stopped" then self:start() end
	return doc
end

--- Record a document's new text (sent after the debounce).
function Client:change(uri, text)
	return self.documents:change(uri, text)
end

--- Close a document.
function Client:close(uri)
	local closed = self.documents:close(uri)
	if self.documents:count() == 0 then self._idle_since = self._clock() end
	return closed
end

--- Tell the server a document was saved.
function Client:saved(uri)
	if self.state ~= "running" then return end
	self.documents:flush(uri)
	self._rpc:notify("textDocument/didSave", { textDocument = { uri = uri } })
end

-- ---------------------------------------------------------------------------
-- Requests
-- ---------------------------------------------------------------------------

-- A request about a place in a document. `line` is zero-based and `byte_column`
-- is the editor's column in bytes; the conversion to a protocol position happens
-- here, after pending edits have been sent so the two sides agree on the text.
function Client:_positional(method, feature, uri, line, byte_column, extra, callback)
	if not self:supports(feature) then
		callback(nil, { message = self.name .. " does not provide " .. feature, unsupported = true })
		return nil
	end
	self.documents:flush(uri)
	local params = {
		textDocument = { uri = uri },
		position = self.documents:toPosition(uri, line, byte_column),
	}
	for key, value in pairs(extra or {}) do params[key] = value end
	local handle, err = self._rpc:request(method, params, callback)
	if not handle then callback(nil, { message = err }) end
	return handle
end

--- Hover. `callback(hover, err)`; `hover` is the server's result or nil.
function Client:hover(uri, line, byte_column, callback)
	return self:_positional("textDocument/hover", "hover", uri, line, byte_column, nil, callback)
end

--- Completion. `callback(items, err, incomplete)` with a plain array of items.
-- @tparam string uri
-- @tparam integer line
-- @tparam integer byte_column
-- @tparam[opt] string trigger the character that opened completion, if one did
-- @tparam function callback
function Client:completion(uri, line, byte_column, trigger, callback)
	local context = trigger and { triggerKind = 2, triggerCharacter = trigger } or { triggerKind = 1 }
	return self:_positional("textDocument/completion", "completion", uri, line, byte_column,
		{ context = context }, function(result, err)
			if err then return callback(nil, err) end
			if type(result) ~= "table" then return callback({}, nil, false) end
			if type(result.items) == "table" then
				return callback(result.items, nil, result.isIncomplete == true)
			end
			callback(result, nil, false)
		end)
end

--- Go to definition. `callback(locations, err)`; each location is
-- `{ uri, range }` whichever form the server answered in.
function Client:definition(uri, line, byte_column, callback)
	return self:_positional("textDocument/definition", "definition", uri, line, byte_column, nil,
		function(result, err)
			if err then return callback(nil, err) end
			local out = {}
			local function add(item)
				if type(item) ~= "table" then return end
				if type(item.targetUri) == "string" then
					out[#out + 1] = { uri = item.targetUri, range = item.targetSelectionRange or item.targetRange }
				elseif type(item.uri) == "string" then
					out[#out + 1] = { uri = item.uri, range = item.range }
				end
			end
			if type(result) == "table" then
				if result.uri or result.targetUri then add(result) else
					for _, item in ipairs(result) do add(item) end
				end
			end
			callback(out)
		end)
end

--- The symbols of a document. `callback(symbols, err)`.
function Client:symbols(uri, callback)
	if not self:supports("symbols") then
		callback(nil, { message = self.name .. " does not provide symbols", unsupported = true })
		return nil
	end
	self.documents:flush(uri)
	local handle, err = self._rpc:request("textDocument/documentSymbol", { textDocument = { uri = uri } },
		function(result, request_err)
			if request_err then return callback(nil, request_err) end
			callback(type(result) == "table" and result or {})
		end)
	if not handle then callback(nil, { message = err }) end
	return handle
end

return Client
