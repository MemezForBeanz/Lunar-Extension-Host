--- JSON-RPC 2.0 on top of a message transport: request ids, replies, timeouts,
-- cancellation, and the server's own requests and notifications.
--
-- Callbacks run inside `handle` (and `tick`, for timeouts), which the client
-- calls from its pump timer, so they are on the UI thread.
--
-- @classmod core.lsp.Rpc
local Json = require("core.lsp.Json")

local Rpc = {}
Rpc.__index = Rpc

--- JSON-RPC and LSP error codes used here.
Rpc.ERRORS = {
	ParseError = -32700,
	InvalidRequest = -32600,
	MethodNotFound = -32601,
	InternalError = -32603,
	RequestCancelled = -32800,
}

--- Seconds before an unanswered request gives up, unless the request says otherwise.
Rpc.DEFAULT_TIMEOUT = 30

--- @tparam table opts
-- @tparam function opts.send `fn(text) -> true | nil, err`: queue one message
-- @tparam[opt] function opts.clock seconds, monotonic enough (default `os.clock`
--   is wrong for this, so the client passes a wall clock)
-- @tparam[opt] function opts.on_error `fn(message)` for protocol trouble
function Rpc.new(opts)
	assert(type(opts) == "table" and type(opts.send) == "function", "Rpc.new: opts.send is required")
	return setmetatable({
		_send = opts.send,
		_clock = opts.clock or os.time,
		_on_error = opts.on_error,
		_next_id = 0,
		_pending = {},        -- id -> { callback, deadline, method }
		_pending_count = 0,
		_notifications = {},  -- method -> fn(params)
		_requests = {},       -- method -> fn(params) -> result | nil, error
	}, Rpc)
end

function Rpc:_error(message)
	if self._on_error then pcall(self._on_error, message) end
end

function Rpc:_write(message)
	message.jsonrpc = "2.0"
	local text, err = Json.encode(message)
	if not text then return nil, "could not encode the message: " .. tostring(err) end
	return self._send(text)
end

--- Send a notification (no reply expected).
-- @treturn[1] boolean true
-- @treturn[2] nil
-- @treturn[2] string
function Rpc:notify(method, params)
	return self:_write({ method = method, params = params })
end

--- Send a request.
--
-- `callback(result, err)` runs exactly once: with the result, or with `nil` and
-- an error table `{ code, message }` (a timeout and a cancellation are errors
-- too, with `err.timeout` or `err.cancelled` set).
--
-- @tparam string method
-- @param params
-- @tparam function callback
-- @tparam[opt] table opts `timeout` in seconds
-- @treturn[1] table a handle with `cancel()` and `done()`
-- @treturn[2] nil
-- @treturn[2] string why it could not be sent
function Rpc:request(method, params, callback, opts)
	self._next_id = self._next_id + 1
	local id = self._next_id
	local ok, err = self:_write({ id = id, method = method, params = params })
	if not ok then return nil, err end

	local entry = {
		callback = callback,
		method = method,
		deadline = self._clock() + ((opts and opts.timeout) or Rpc.DEFAULT_TIMEOUT),
	}
	self._pending[id] = entry
	self._pending_count = self._pending_count + 1

	local rpc = self
	local handle = {}
	function handle.done() return rpc._pending[id] ~= entry end
	function handle.cancel()
		if rpc._pending[id] ~= entry then return false end
		rpc:_settle(id, nil, { code = Rpc.ERRORS.RequestCancelled, message = "cancelled", cancelled = true })
		-- Best effort: the server may already have answered.
		rpc:notify("$/cancelRequest", { id = id })
		return true
	end
	return handle
end

function Rpc:_settle(id, result, err)
	local entry = self._pending[id]
	if not entry then return false end
	self._pending[id] = nil
	self._pending_count = self._pending_count - 1
	if entry.callback then
		local ok, cb_err = xpcall(function() entry.callback(result, err) end, debug.traceback)
		if not ok then self:_error("callback for " .. tostring(entry.method) .. " failed: " .. tostring(cb_err)) end
	end
	return true
end

--- Requests still waiting for a reply.
function Rpc:pending()
	return self._pending_count
end

--- Handle a notification from the server. `fn(params)`; nil removes it.
function Rpc:onNotification(method, fn)
	self._notifications[method] = fn
end

--- Answer a request from the server. `fn(params)` returns the result, or
-- `nil, { code, message }`. Unhandled methods are refused with MethodNotFound.
function Rpc:onRequest(method, fn)
	self._requests[method] = fn
end

local function has_id(message)
	return message.id ~= nil and message.id ~= Json.null
end

function Rpc:_dispatch(message)
	if type(message) ~= "table" then
		return self:_error("the server sent a message that is not an object")
	end
	local method = message.method
	if type(method) == "string" then
		local params = message.params
		if params == Json.null then params = nil end
		if has_id(message) then
			local handler = self._requests[method]
			local reply = { id = message.id }
			if not handler then
				reply.error = { code = Rpc.ERRORS.MethodNotFound, message = "unhandled method: " .. method }
			else
				local ok, result, err = pcall(handler, params)
				if not ok then
					reply.error = { code = Rpc.ERRORS.InternalError, message = tostring(result) }
				elseif err ~= nil then
					reply.error = err
				else
					reply.result = result == nil and Json.null or result
				end
			end
			self:_write(reply)
		else
			local handler = self._notifications[method]
			if handler then
				local ok, err = xpcall(function() handler(params) end, debug.traceback)
				if not ok then self:_error("handler for " .. method .. " failed: " .. tostring(err)) end
			end
		end
		return
	end
	if has_id(message) then
		local err = message.error
		if err == Json.null then err = nil end
		local result = message.result
		if result == Json.null then result = nil end
		if type(err) == "table" then
			err = { code = tonumber(err.code) or Rpc.ERRORS.InternalError,
				message = type(err.message) == "string" and err.message or "request failed", data = err.data }
		elseif err ~= nil then
			err = { code = Rpc.ERRORS.InternalError, message = tostring(err) }
		end
		-- A reply to a request already timed out or cancelled is simply late.
		self:_settle(message.id, result, err)
		return
	end
	self:_error("the server sent a message with neither a method nor an id")
end

--- Take one message body from the transport.
-- A batch (a JSON array) is accepted, though LSP servers don't send them.
function Rpc:handle(text)
	local message, err = Json.decode(text)
	if message == nil then
		return self:_error("the server sent invalid JSON: " .. tostring(err))
	end
	if type(message) == "table" and message[1] ~= nil then
		for _, item in ipairs(message) do self:_dispatch(item) end
		return
	end
	self:_dispatch(message)
end

--- Expire requests whose deadline has passed. Call it from the pump timer.
function Rpc:tick()
	if self._pending_count == 0 then return end
	local now = self._clock()
	local late
	for id, entry in pairs(self._pending) do
		if now >= entry.deadline then
			late = late or {}
			late[#late + 1] = id
		end
	end
	if not late then return end
	table.sort(late)
	for _, id in ipairs(late) do
		local method = self._pending[id] and self._pending[id].method
		self:_settle(id, nil, { code = Rpc.ERRORS.RequestCancelled,
			message = tostring(method) .. " timed out", timeout = true })
		self:notify("$/cancelRequest", { id = id })
	end
end

--- Fail every waiting request (the connection is gone).
-- @tparam string reason
function Rpc:failAll(reason)
	local ids = {}
	for id in pairs(self._pending) do ids[#ids + 1] = id end
	table.sort(ids)
	for _, id in ipairs(ids) do
		self:_settle(id, nil, { code = Rpc.ERRORS.InternalError, message = reason, closed = true })
	end
end

return Rpc
