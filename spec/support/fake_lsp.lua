-- A language server that lives in the test: a stand-in for the native `process`
-- handle whose other end is a table of Lua handlers. What the client writes is
-- parsed as Content-Length frames and dispatched; what the handlers answer is
-- queued for the client's next read. Nothing here sleeps or spawns.
--
--   local server = fake.server({ ["textDocument/hover"] = function(params) return { contents = "hi" } end })
--   local client = Client.new({ spawn = function() return server end, ... })
local Json = require("core.lsp.Json")

local M = {}

--- Return this from a request handler to leave the request unanswered.
M.NO_REPLY = {}

function M.frame(body)
	return "Content-Length: " .. #body .. "\r\n\r\n" .. body
end

--- A clock the test moves by hand.
function M.clock(start)
	local now = start or 1000
	return setmetatable({
		advance = function(seconds) now = now + seconds end,
		now = function() return now end,
	}, { __call = function() return now end })
end

local DEFAULT_CAPABILITIES = {
	textDocumentSync = 1,
	hoverProvider = true,
	completionProvider = { triggerCharacters = Json.array({ ".", ":" }) },
	definitionProvider = true,
	documentSymbolProvider = true,
}

--- Build a fake server process.
-- @tparam[opt] table handlers method -> fn(params, server, message)
-- @tparam[opt] table opts `capabilities`, `chunk` (bytes handed over per read)
function M.server(handlers, opts)
	opts = opts or {}
	local server = {
		received = {},     -- every message the client sent, decoded, in order
		replies = {},      -- id -> the client's reply to a server request
		out = "",
		err = "",
		inbuf = "",
		exit = nil,
		closed = false,
		stalled = false,   -- true: accept writes but never read them
		backlog = 0,
		chunk = opts.chunk,
	}
	handlers = handlers or {}

	local defaults = {
		initialize = function()
			return { capabilities = opts.capabilities or DEFAULT_CAPABILITIES, serverInfo = { name = "fake" } }
		end,
		shutdown = function() return Json.null end,
		exit = function(_, self) self.exit = 0 end,
	}

	function server:emit(message)
		message.jsonrpc = "2.0"
		self.out = self.out .. M.frame(assert(Json.encode(message)))
	end
	function server:raw(bytes) self.out = self.out .. bytes end
	function server:reply(id, result, err)
		if err then self:emit({ id = id, error = err }) else self:emit({ id = id, result = result == nil and Json.null or result }) end
	end
	function server:notify(method, params) self:emit({ method = method, params = params }) end
	function server:request(id, method, params) self:emit({ id = id, method = method, params = params }) end
	function server:die(code) self.exit = code or 1 end

	function server:_dispatch(message)
		self.received[#self.received + 1] = message
		local method = message.method
		if not method then
			self.replies[message.id] = message
			return
		end
		local handler = handlers[method]
		if handler == nil then handler = defaults[method] end
		if message.id ~= nil then
			if not handler then
				return self:reply(message.id, nil, { code = -32601, message = "unhandled: " .. method })
			end
			local result, err = handler(message.params, self, message)
			if result ~= M.NO_REPLY then self:reply(message.id, result, err) end
		elseif handler then
			handler(message.params, self, message)
		end
	end

	-- The process interface the transport uses.
	function server:write(data)
		if self.closed or self.stdin_closed or self.exit ~= nil then return nil, "stdin is closed" end
		if self.stalled then
			self.backlog = self.backlog + #data
			return true
		end
		self.inbuf = self.inbuf .. data
		while true do
			local head_end, body_start = self.inbuf:find("\r\n\r\n", 1, true)
			if not head_end then break end
			local length = tonumber(self.inbuf:sub(1, head_end):match("Content%-Length: (%d+)"))
			assert(length, "the client sent a frame without Content-Length")
			if #self.inbuf < body_start + length then break end
			local body = self.inbuf:sub(body_start + 1, body_start + length)
			self.inbuf = self.inbuf:sub(body_start + length + 1)
			self:_dispatch(assert(Json.decode(body)))
		end
		return true
	end
	function server:read(stream)
		if stream == "stderr" then
			local text = self.err
			self.err = ""
			if text == "" and (self.exit ~= nil or self.closed) then return nil end
			return text
		end
		if self.out ~= "" then
			local n = self.chunk or #self.out
			local piece = self.out:sub(1, n)
			self.out = self.out:sub(n + 1)
			return piece
		end
		if self.exit ~= nil or self.closed then return nil end
		return ""
	end
	function server:poll() return self.exit end
	function server:pending() return self.backlog end
	function server:close_stdin() self.stdin_closed = true end
	function server:close() self.closed = true end
	function server:kill() self.exit = self.exit or 1 end

	--- The methods the client has sent so far, in order.
	function server:methods()
		local out = {}
		for _, message in ipairs(self.received) do
			if message.method then out[#out + 1] = message.method end
		end
		return out
	end
	--- The last message sent with a method, or nil.
	function server:last(method)
		for i = #self.received, 1, -1 do
			if self.received[i].method == method then return self.received[i] end
		end
		return nil
	end
	--- How many messages with a method were sent.
	function server:count(method)
		local n = 0
		for _, message in ipairs(self.received) do
			if message.method == method then n = n + 1 end
		end
		return n
	end
	return server
end

return M
