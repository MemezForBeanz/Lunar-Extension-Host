--- Language Server Protocol base transport: `Content-Length` framed messages
-- over a child process's stdin and stdout.
--
-- Nothing here blocks. `pump` takes whatever the server has written so far and
-- hands on each complete message; `send` queues bytes on the process's stdin
-- stream (a writer thread delivers them, see the native `process` module). A
-- server that stops reading shows up as a growing `backlog`, not a frozen window.
--
-- The transport knows nothing about JSON: a message is the body's bytes.
--
-- @classmod core.lsp.Transport
local Transport = {}
Transport.__index = Transport

--- A header block longer than this is not a header block.
Transport.MAX_HEADER = 8 * 1024
--- The largest body accepted. A server announcing more is treated as broken.
Transport.MAX_BODY = 64 * 1024 * 1024
--- Most bytes taken from the server in one `pump`, so a flood is spread over
-- several ticks instead of stalling one.
Transport.PUMP_BUDGET = 4 * 1024 * 1024

--- Wrap a running process.
-- @tparam table opts
-- @param opts.process a `process` handle started with `stdin = true`
-- @tparam function opts.on_message `fn(body)` for each complete message
-- @tparam[opt] function opts.on_stderr `fn(text)` for what the server logs
-- @tparam[opt] function opts.on_close `fn(reason, exit_code)`, once, when the
--   server exits, closes its output, or breaks the framing
function Transport.new(opts)
	assert(type(opts) == "table" and opts.process, "Transport.new: opts.process is required")
	assert(type(opts.on_message) == "function", "Transport.new: opts.on_message is required")
	return setmetatable({
		_process = opts.process,
		_on_message = opts.on_message,
		_on_stderr = opts.on_stderr,
		_on_close = opts.on_close,
		_pieces = {},
		_size = 0,
		_need = nil,   -- body bytes still awaited, once a header has been read
		_closed = false,
		sent = 0,
		received = 0,
	}, Transport)
end

--- Is the connection still usable?
function Transport:isOpen()
	return not self._closed
end

--- Frame and queue one message.
-- @tparam string body
-- @treturn[1] boolean true
-- @treturn[2] nil
-- @treturn[2] string why it could not be queued
function Transport:send(body)
	if self._closed then return nil, "the server connection is closed" end
	local ok, err = self._process:write("Content-Length: " .. #body .. "\r\n\r\n" .. body)
	if not ok then return nil, err or "the server's input is closed" end
	self.sent = self.sent + 1
	return true
end

--- Bytes queued for the server that it has not read yet.
function Transport:backlog()
	if self._closed or not self._process.pending then return 0 end
	local ok, pending = pcall(self._process.pending, self._process)
	return ok and tonumber(pending) or 0
end

function Transport:_finish(reason, exit_code)
	if self._closed then return end
	self._closed = true
	pcall(function() self._process:close() end)
	if self._on_close then self._on_close(reason, exit_code) end
end

--- End the connection and the server process. `on_close` is not called: the
-- caller asked for it.
function Transport:close()
	if self._closed then return end
	self._closed = true
	pcall(function() self._process:close() end)
end

local function header_length(header)
	for line in header:gmatch("[^\r\n]+") do
		local name, value = line:match("^([%w%-]+)%s*:%s*(.-)%s*$")
		if name and name:lower() == "content-length" then
			local n = tonumber(value)
			if n and n >= 0 and n % 1 == 0 then return n end
			return nil
		end
	end
	return nil
end

-- Take complete messages off the front of the buffer.
function Transport:_drain()
	while not self._closed do
		if not self._need then
			if self._size == 0 then return end
			local data = table.concat(self._pieces)
			local head_end, body_start = data:find("\r\n\r\n", 1, true)
			if not head_end then
				if #data > Transport.MAX_HEADER then
					return self:_finish("the server sent something that is not a protocol header")
				end
				self._pieces = { data }
				return
			end
			local length = header_length(data:sub(1, head_end - 1))
			if not length then
				return self:_finish("the server sent a header without a valid Content-Length")
			end
			if length > Transport.MAX_BODY then
				return self:_finish("the server announced a " .. length .. " byte message")
			end
			local rest = data:sub(body_start + 1)
			self._pieces, self._size, self._need = { rest }, #rest, length
		end
		if self._size < self._need then return end
		local data = table.concat(self._pieces)
		local body = data:sub(1, self._need)
		local rest = data:sub(self._need + 1)
		self._pieces, self._size, self._need = { rest }, #rest, nil
		self.received = self.received + 1
		self._on_message(body)
	end
end

--- Take what the server has written and dispatch each complete message.
-- Call it from a timer. @treturn boolean false once the connection has ended
function Transport:pump()
	if self._closed then return false end
	local process = self._process

	if self._on_stderr then
		for _ = 1, 16 do
			local text = process:read("stderr")
			if not text or text == "" then break end
			self._on_stderr(text)
		end
	end

	local taken, ended = 0, false
	while taken < Transport.PUMP_BUDGET do
		local chunk, err = process:read("stdout")
		if chunk == nil then
			ended = err or true
			break
		end
		if chunk == "" then break end
		taken = taken + #chunk
		self._pieces[#self._pieces + 1] = chunk
		self._size = self._size + #chunk
	end
	if taken > 0 then self:_drain() end
	if self._closed then return false end

	if ended then
		local code = process:poll()
		self:_finish(type(ended) == "string" and ended or "the server closed its output", code)
		return false
	end
	local code = process:poll()
	if code ~= nil and taken == 0 then
		self:_finish("the server exited", code)
		return false
	end
	return true
end

return Transport
