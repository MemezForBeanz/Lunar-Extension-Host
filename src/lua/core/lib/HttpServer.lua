--- Small, connection-closing HTTP/1.1 server driven by the host's Copas loop.
-- Requests use origin-form targets and Content-Length framing (absent means no
-- body). Headers are limited to 100 fields, 8 KiB per line and 32 KiB overall;
-- duplicates, transfer encodings and Expect are rejected. read_timeout bounds
-- the entire request read. Repeated query keys use the last value. req.path
-- remains encoded; named parameters and query fields are percent-decoded.
-- Routes are explicit: HEAD/OPTIONS are not synthesized. stop() also closes
-- active clients, but cannot cancel arbitrary work already running in handlers.
-- @module core.lib.HttpServer

local socket = require("socket")
local cjson = require("cjson")
local bit = require("bit")
local async = require("core.lib.async")
local copas = async.copas
if not copas then
	local saved = package.loaded["socket.http"]
	package.loaded["socket.http"] = nil
	local ok, result = pcall(require, "copas")
	package.loaded["socket.http"] = saved
	if ok then copas = result end
end

local M = {}
local file_responses = setmetatable({}, { __mode = "k" })

--- Authorize in the extension first; root and relative name come from its catalog.
-- Returns an opaque, reusable response. Files are opened on the native worker.
function M.fileResponse(root, relative, opts)
	opts = opts or {}
	local response = {}
	file_responses[response] = require("file_stream").target(root, relative,
		opts.mime or "application/octet-stream")
	return response
end

local Server = {}
Server.__index = Server
local TOKEN = "^[!#$%%&'*+%.%^_`|~%w-]+$"
local reasons = { [200] = "OK", [201] = "Created", [204] = "No Content",
	[400] = "Bad Request", [401] = "Unauthorized", [404] = "Not Found",
	[405] = "Method Not Allowed", [408] = "Request Timeout", [413] = "Payload Too Large",
	[417] = "Expectation Failed", [500] = "Internal Server Error", [501] = "Not Implemented" }

local function failure(status, message, headers)
	return { status = status, json = { error = message or reasons[status] }, headers = headers }
end

local function decode(value, plus)
	if plus then value = value:gsub("+", " ") end
	if value:gsub("%%[%da-fA-F][%da-fA-F]", ""):find("%%") then return nil end
	return (value:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end))
end

local function log_error(self, err)
	if self.log then pcall(self.log, "error", err) end
end

local function audit(self, req, status, started)
	if self.log then
		pcall(function()
			self.log("info", cjson.encode({ event = "http_request",
				token = req and req.auth or "-", method = req and req.method or "-",
				path = req and req.path or "-", status = status,
				ms = math.max(0, (socket.gettime() - started) * 1000) }))
		end)
	end
end

-- Visit every byte and every configured token; never return at the first mismatch.
local function authenticate(tokens, supplied)
	local name
	for token, identity in pairs(tokens) do
		local diff = bit.bxor(#token, #supplied)
		for i = 1, math.max(#token, #supplied) do
			diff = bit.bor(diff, bit.bxor(token:byte(i) or 0, supplied:byte(i) or 0))
		end
		if diff == 0 then name = identity end
	end
	return name
end

--- Construct a server. No socket is opened until start().
-- Fails closed: it listens on 127.0.0.1 unless `host` says otherwise, and needs
-- `tokens` unless `allow_anonymous = true` (then every route is public).
-- @tparam table opts host, port, tokens, allow_anonymous, max_body, read_timeout, tls and log
-- @treturn table server
function M.new(opts)
	opts = opts or {}
	local self = setmetatable({ host = opts.host or "127.0.0.1", port = opts.port or 8470,
		max_body = opts.max_body or 1048576, read_timeout = opts.read_timeout or 10,
		tls = opts.tls, log = opts.log, routes = {}, clients = {}, client_count = 0,
		transfers = {}, max_connections = opts.max_connections or 64 }, Server)
	assert(type(self.max_connections) == "number" and self.max_connections >= 1
		and self.max_connections < math.huge and self.max_connections % 1 == 0, "invalid max_connections")
	assert(self.max_body >= 0 and self.max_body < math.huge and self.max_body % 1 == 0, "invalid max_body")
	assert(self.read_timeout > 0 and self.read_timeout < math.huge, "invalid read_timeout")
	assert(opts.tokens or opts.allow_anonymous == true,
		"HttpServer.new: tokens required (or allow_anonymous = true)")
	if opts.tokens then
		self.tokens = {}
		for token, name in pairs(opts.tokens) do
			assert(type(token) == "string" and #token > 0 and type(name) == "string", "invalid token")
			self.tokens[token] = name
		end
	end
	return self
end

--- Register a literal path with whole-segment :name parameters; first match wins.
-- @treturn table opaque handle for unroute()
function Server:route(method, pattern, handler, opts)
	assert(type(method) == "string" and method:match(TOKEN), "invalid method")
	assert(type(pattern) == "string" and pattern:sub(1, 1) == "/", "invalid route path")
	assert(type(handler) == "function", "handler must be a function")
	local names, parts = {}, {}
	for segment in (pattern .. "/"):gmatch("(.-)/") do
		local name = segment:match("^:([%a_][%w_]*)$")
		if name then
			names[#names + 1] = name
			parts[#parts + 1] = "([^/]+)"
		else
			parts[#parts + 1] = segment:gsub("([^%w])", "%%%1")
		end
	end
	local handle = { method = method:upper(), pattern = "^" .. table.concat(parts, "/") .. "$",
		names = names, handler = handler, public = opts and opts.public }
	self.routes[#self.routes + 1] = handle
	return handle
end

--- Remove a registered route; returns whether it belonged to this server.
function Server:unroute(handle)
	for i, route in ipairs(self.routes) do
		if route == handle then table.remove(self.routes, i) return true end
	end
	return false
end

local function read_request(self, conn, client, metadata)
	local deadline, total, buffer = socket.gettime() + self.read_timeout, 0, ""
	local function timeout()
		local remaining = deadline - socket.gettime()
		if remaining <= 0 then return false end
		conn:settimeout(remaining)
		return true
	end
	-- Partial reads avoid both unbounded *l allocations and waiting for a full
	-- chunk when a short request has already arrived.
	local function line()
		while true do
			local ending = buffer:find("\n", 1, true)
			if ending then
				if ending > 8192 or total + ending > 32768 or buffer:sub(ending - 1, ending - 1) ~= "\r" then return nil end
				local value = buffer:sub(1, ending - 2)
				buffer, total = buffer:sub(ending + 1), total + ending
				return value
			end
			if #buffer >= 8192 or total + #buffer >= 32768 or not timeout() then return nil end
			local data, _, partial = copas.receivePartial(conn.socket, math.min(4096, 32768 - total - #buffer))
			data = data or partial
			if not data or data == "" then return nil end
			buffer = buffer .. data
		end
	end
	local first = line()
	local method, target, version
	if first then method, target, version = first:match("^(%S+) (%S+) HTTP/(1%.[01])$") end
	if not method or not method:match(TOKEN) or target:sub(1, 1) ~= "/" then return nil, failure(400) end
	metadata.method, metadata.path = method, target:match("^[^?]*")
	local headers, count = {}, 0
	while true do
		local h = line()
		if not h then return nil, failure(400) end
		if h == "" then break end
		count = count + 1
		local key, value = h:match("^([^:]+):[ \t]*(.-)[ \t]*$")
		if count > 100 or not key or not key:match(TOKEN) or value:find("[%z\1-\8\10-\31\127]") then
			return nil, failure(400)
		end
		key = key:lower()
		-- Reject duplicate framing/auth fields rather than interpret conflicting values.
		if headers[key] then return nil, failure(400, "duplicate header") end
		headers[key] = value
	end
	if version == "1.1" and (not headers.host or headers.host == "") then return nil, failure(400) end
	if headers["transfer-encoding"] then return nil, failure(501, "transfer encoding unsupported") end
	local length = headers["content-length"]
	if length and not length:match("^%d+$") then return nil, failure(400) end
	length = tonumber(length or "0")
	if length > self.max_body then return nil, failure(413) end
	if headers.expect then return nil, failure(417) end
	local path, query_string = target:match("^([^?]*)%??(.*)$")
	if target:find("#", 1, true) or not decode(path) then return nil, failure(400) end
	local query = {}
	for pair in query_string:gmatch("[^&]+") do
		local key, value = pair:match("^([^=]*)=?(.*)$")
		key, value = decode(key, true), decode(value, true)
		if not key or not value then return nil, failure(400) end
		query[key] = value
	end
	local body = ""
	if length > 0 then
		body = buffer:sub(1, length)
		if #body < length then
			if not timeout() then return nil, failure(400, "incomplete body") end
			local rest = conn:receive(length - #body)
			if not rest then return nil, failure(400, "incomplete body") end
			body = body .. rest
		end
	end
	local req = { method = method, path = path, query = query, headers = headers,
		params = {}, body = body, client = client }
	local media = (headers["content-type"] or ""):lower():match("^%s*([^;%s]+)")
	if media == "application/json" or (media and media:match("^application/.+%+json$")) then
		local ok, json = pcall(cjson.decode, body)
		if not ok then return nil, failure(400, "invalid JSON") end
		req.json = json
	end
	return req
end

local function dispatch(self, req)
	local allowed = {}
	for _, route in ipairs(self.routes) do
		local captures = { req.path:match(route.pattern) }
		if #captures > 0 then
			allowed[route.method] = true
			if route.method == req.method then
				for i, name in ipairs(route.names) do req.params[name] = decode(captures[i]) end
				if self.tokens and not route.public then
					local supplied = (req.headers.authorization or ""):match("^[Bb][Ee][Aa][Rr][Ee][Rr] +(%S+)$")
					req.auth = authenticate(self.tokens, supplied or "")
					if not req.auth then
						return failure(401, "unauthorized", { ["WWW-Authenticate"] = "Bearer" })
					end
				end
				return route.handler(req)
			end
		end
	end
	local methods = {}
	for method in pairs(allowed) do methods[#methods + 1] = method end
	table.sort(methods)
	if #methods > 0 then return failure(405, nil, { Allow = table.concat(methods, ", ") }) end
	return failure(404)
end

local function serialize(res, method)
	if res == nil then res = { status = 204 } end
	assert(type(res) == "table", "invalid response")
	if res.status == nil and res.json == nil and res.body == nil then res = { json = res } end
	local status = res.status or 200
	assert(type(status) == "number" and status >= 200 and status <= 599 and status % 1 == 0, "invalid status")
	local body = res.json ~= nil and cjson.encode(res.json) or (res.body or "")
	assert(type(body) == "string", "invalid response body")
	if status == 204 or status == 304 then body = "" end
	local headers = {}
	for key, value in pairs(res.headers or {}) do
		assert(type(key) == "string" and key:match(TOKEN), "invalid response header")
		value = tostring(value)
		assert(not value:find("[%z\1-\31\127]"), "invalid response header value")
		headers[key:lower()] = value
	end
	if res.json ~= nil then headers["content-type"] = "application/json; charset=utf-8" end
	headers["content-length"], headers.connection = tostring(#body), "close"
	headers["transfer-encoding"] = nil
	local lines = { "HTTP/1.1 " .. status .. " " .. (reasons[status] or "Response") }
	for key, value in pairs(headers) do lines[#lines + 1] = key .. ": " .. value end
	return table.concat(lines, "\r\n") .. "\r\n\r\n" .. (method == "HEAD" and "" or body)
end

--- Bind and register with Copas without running its loop. Port 0 exposes the bound port.
-- @return true on success, or nil and an error
function Server:start()
	if self.listener then return true end
	if not copas then return nil, "copas unavailable" end
	local tls
	if self.tls then
		tls = { mode = "server", protocol = "any", options = { "all", "no_sslv2", "no_sslv3", "no_tlsv1", "no_tlsv1_1" },
			certificate = self.tls.certificate, key = self.tls.key, verify = "none" }
		if not tls.certificate or not tls.key then return nil, "TLS requires certificate and key" end
		local ok, ctx, err = pcall(function() return require("ssl").newcontext(tls) end)
		if not ok then return nil, ctx end
		if not ctx then return nil, err end
	end
	-- socket.bind enables SO_REUSEADDR even on Windows, where that permits a
	-- second listener to steal an occupied port. Only enable it on POSIX, where
	-- without it a restart can't bind while the last run's connections sit in
	-- TIME_WAIT. tcp4/tcp6, not tcp(): LuaSocket 3's tcp() creates the socket
	-- only at bind, so an option set before that is silently dropped.
	local listener, err = (self.host:find(":", 1, true) and socket.tcp6 or socket.tcp4)()
	if not listener then return nil, err end
	if package.config:sub(1, 1) ~= "\\" then
		local reused, reuse_error = listener:setoption("reuseaddr", true)
		if not reused then listener:close() return nil, "SO_REUSEADDR: " .. tostring(reuse_error) end
	end
	local bound, bind_error = listener:bind(self.host, self.port)
	if not bound then listener:close() return nil, bind_error end
	local listening, listen_error = listener:listen(128)
	if not listening then listener:close() return nil, listen_error end
	local _, port = listener:getsockname()
	local ok, added = pcall(copas.addserver, listener, function(raw)
		local started = socket.gettime()
		if self.client_count >= self.max_connections then
			raw:settimeout(0)
			raw:send("HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
			raw:close()
			audit(self, nil, 503, started)
			return
		end
		local ip, peerport = raw:getpeername()
		local conn = copas.wrap(raw, tls)
		self.clients[conn] = true
		self.client_count = self.client_count + 1
		conn:settimeout(self.read_timeout)
		local req, status = nil, 500
		local metadata = {}
		local success, problem = xpcall(function()
			if tls then assert(conn:dohandshake()) end
			local bad
			req, bad = read_request(self, conn, tostring(ip) .. ":" .. tostring(peerport), metadata)
			local worked, response = xpcall(function()
				local res = bad
				if req then res = dispatch(self, req) end
				if file_responses[res] then
					assert(req.method == "GET" or req.method == "HEAD", "file response requires GET or HEAD")
					return { target = file_responses[res] }
				end
				local wire = serialize(res, req and req.method)
				status = res == nil and 204 or (res.status or 200)
				return wire
			end, debug.traceback)
			if not worked then
				status = 500
				log_error(self, response)
				response = serialize(failure(500, "internal error"), req and req.method)
			end
			conn:settimeout(self.read_timeout)
			if type(response) == "table" and response.target then
				local native = require("file_stream")
				local h = req.headers
				local task = native.start(response.target, conn.socket:getfd(), tls and conn.socket or nil,
					req.method == "HEAD", h.range or "", h["if-match"] or "",
					h["if-none-match"] or "", h["if-range"] or "",
					h["if-modified-since"] or "", h["if-unmodified-since"] or "")
				self.clients[conn] = task
				self.transfers[task] = conn
				while true do
					local done, code = native.poll(task)
					if done then status = code break end
					copas.sleep(0.005)
				end
				self.transfers[task] = nil
				if self.clients[conn] then self.clients[conn] = true end
			else
				conn:send(response)
			end
		end, debug.traceback)
		if not success then log_error(self, problem) end
		audit(self, req or metadata, status, started)
		pcall(conn.close, conn)
		if self.clients[conn] then
			self.clients[conn] = nil
			self.client_count = self.client_count - 1
		end
	end)
	if not ok then copas.removeserver(listener) return nil, added end
	self.listener, self.port = listener, tonumber(port)
	return true
end

--- Close the listener and active clients. Safe to call repeatedly.
function Server:stop()
	if self.listener then
		copas.removeserver(self.listener)
		self.listener = nil
	end
	-- Workers retain exclusive socket/SSL ownership through cancellation. Their
	-- coroutine reaps completed work and then closes the connection; stop never
	-- waits for disk I/O or joins an unfinished thread on the Lua event loop.
	for task in pairs(self.transfers) do require("file_stream").cancel(task) end
	for conn, task in pairs(self.clients) do
		if task == true then pcall(conn.close, conn) end
	end
	self.clients = {}
	self.client_count = 0
end

function Server:pendingFiles()
	return next(self.transfers) ~= nil
end

return M
