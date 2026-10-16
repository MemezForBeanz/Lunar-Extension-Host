--- HTTP(S) requests that never block the window, for the host and extensions.
--
-- Extensions reach this through `ctx:http(request, callback)`; see
-- `HostAPI:http`. Requests run as tasks on the shared copas scheduler
-- (`core.lib.async`), so a slow or unreachable server never freezes the UI.
--
-- HTTPS checks the server the same way `core.lib.https` does: the certificate
-- chain against the bundled CA store (or `cafile`), **and** that the certificate
-- was issued for the host in the URL. `verify = "none"` turns both off (the
-- connection is still encrypted).
--
-- ### Request
--
--     {
--       url       = "https://api.example.com/v1/items",   -- http:// or https://
--       method    = "GET",            -- default GET, or POST when there is a body
--       headers   = { accept = "application/json" },
--       body      = "raw bytes",      -- or:
--       json      = { name = "x" },   -- encoded, with content-type application/json
--       timeout   = 30,               -- seconds, per connection step
--       verify    = "peer",           -- or "none"
--       cafile    = "C:\\certs\\corp-root.pem",
--       max_bytes = 32 * 1024 * 1024, -- larger responses fail
--     }
--
-- ### Response
--
--     { status = 200, ok = true, headers = { ["content-type"] = ... },
--       body = "...", url = <final URL after redirects> }
--
-- plus `res:json()`, which decodes the body (or returns nil and an error).
-- A non-2xx status is still a response (`ok = false`); only transport failures
-- (DNS, refused, timeout, TLS, too large) are errors. GET and HEAD follow up to
-- five redirects; a redirect from https:// to http:// is refused.
--
-- @module core.lib.http

local M = {}

M.DEFAULT_TIMEOUT = 30
M.MAX_TIMEOUT = 600
M.DEFAULT_MAX_BYTES = 32 * 1024 * 1024
M.MAX_REDIRECTS = 5

local METHODS = { GET = true, HEAD = true, POST = true, PUT = true, PATCH = true, DELETE = true, OPTIONS = true }

local function lazy(name)
	local ok, mod = pcall(require, name)
	return ok and mod or nil
end

--- Check and normalize a request table (pure).
-- @tparam table req see the module doc
-- @treturn[1] table normalized request
-- @treturn[2] nil
-- @treturn[2] string what is wrong with it
function M.prepare(req)
	if type(req) ~= "table" then return nil, "a request is a table with a url" end
	local url = req.url
	if type(url) ~= "string" then return nil, "the request has no url" end
	local scheme = url:match("^(%a[%w+.-]*)://")
	scheme = scheme and scheme:lower()
	if scheme ~= "http" and scheme ~= "https" then return nil, "only http:// and https:// URLs are supported" end
	if url:find("[%z\1-\32\127]") then return nil, "the url contains spaces or control characters" end

	local out = { url = url, scheme = scheme, headers = {} }
	for k, v in pairs(type(req.headers) == "table" and req.headers or {}) do
		if type(k) ~= "string" or k:find("[%c:]") or tostring(v):find("[\r\n]") then
			return nil, "invalid header: " .. tostring(k)
		end
		out.headers[k:lower()] = tostring(v)
	end

	if req.json ~= nil then
		if req.body ~= nil then return nil, "give body or json, not both" end
		local cjson = lazy("cjson")
		if not cjson then return nil, "JSON is unavailable" end
		local ok, encoded = pcall(cjson.encode, req.json)
		if not ok then return nil, "could not encode json: " .. tostring(encoded) end
		out.body = encoded
		out.headers["content-type"] = out.headers["content-type"] or "application/json"
	elseif req.body ~= nil then
		if type(req.body) ~= "string" then return nil, "body must be a string" end
		out.body = req.body
	end
	if out.body then out.headers["content-length"] = tostring(#out.body) end

	local method = req.method and tostring(req.method):upper() or (out.body and "POST" or "GET")
	if not METHODS[method] then return nil, "unsupported method " .. method end
	out.method = method

	local timeout = tonumber(req.timeout) or M.DEFAULT_TIMEOUT
	if timeout <= 0 then return nil, "timeout must be positive" end
	out.timeout = math.min(timeout, M.MAX_TIMEOUT)

	out.verify = req.verify or "peer"
	if out.verify ~= "peer" and out.verify ~= "none" then return nil, 'verify is "peer" or "none"' end
	if req.cafile ~= nil and type(req.cafile) ~= "string" then return nil, "cafile must be a path" end
	out.cafile = req.cafile
	out.max_bytes = tonumber(req.max_bytes) or M.DEFAULT_MAX_BYTES
	return out
end

--- Where a redirect goes, or nil and why it isn't followed (pure).
-- @tparam string from the URL that answered
-- @tparam string location its `Location` header
-- @treturn[1] string the absolute target
-- @treturn[2] nil
-- @treturn[2] string why not
function M.redirect_target(from, location)
	if type(location) ~= "string" or location == "" then return nil, "redirect without a location" end
	local url = require("socket.url")
	local target = url.absolute(from, location)
	local scheme = (target:match("^(%a[%w+.-]*)://") or ""):lower()
	if scheme ~= "http" and scheme ~= "https" then return nil, "redirect to an unsupported URL" end
	if from:lower():match("^https://") and scheme == "http" then
		return nil, "refused a redirect from https:// to http://"
	end
	return target
end

-- An ltn12 sink that keeps the body and stops past `limit` bytes.
local function limited_sink(chunks, limit)
	local size = 0
	return function(chunk, err)
		if chunk then
			size = size + #chunk
			if size > limit then return nil, "response is larger than " .. limit .. " bytes" end
			chunks[#chunks + 1] = chunk
		end
		return 1, err
	end
end

local Response = {}
Response.__index = Response

--- Decode the body as JSON.
-- @treturn[1] any the decoded value
-- @treturn[2] nil
-- @treturn[2] string why not
function Response:json()
	local cjson = lazy("cjson")
	if not cjson then return nil, "JSON is unavailable" end
	local ok, value = pcall(cjson.decode, self.body or "")
	if not ok then return nil, "the response is not JSON: " .. tostring(value) end
	return value
end

-- The trust parameters for an https request.
local function tls_params(p)
	local https = require("core.lib.https")
	local params = {
		mode = "client", protocol = "any", verify = p.verify,
		options = { "all", "no_sslv2", "no_sslv3", "no_tlsv1", "no_tlsv1_1" },
	}
	if p.verify ~= "none" then
		params.cafile = p.cafile or https.bundled_cafile()
		if not params.cafile then return nil, "no trust store: set cafile or ship certs/cacert.pem" end
	end
	return params
end

--- The `create` function copas.http uses to open a connection: a copas socket
-- that does the TLS handshake (with SNI) and then checks the host name, and that
-- applies this request's timeout. Exposed for the specs.
-- @tparam table p a prepared request
-- @tparam table copas the copas module
-- @tparam table socket LuaSocket
-- @tparam[opt] table params TLS parameters (https only)
-- @treturn function
function M.connector(p, copas, socket, params)
	local https = require("core.lib.https")
	return function(reqt)
		local conn
		if p.scheme == "https" then
			conn = copas.wrap(socket.tcp(), { wrap = params, sni = { names = reqt.host } })
			local plain_connect = conn.connect
			conn.connect = function(self, host, port)
				local ok, err = plain_connect(self, host, port)
				if not ok then return ok, err end
				if params.verify ~= "none" then
					local cert = self.socket:getpeercertificate()
					if not https.certificate_matches(cert, host) then
						self:close()
						return nil, "certificate is not valid for host " .. tostring(host)
					end
				end
				return ok
			end
			-- LuaSocket fills in port 80 when the URL has none.
			if not reqt.url:match("^%a+://[^/]*:%d+") then reqt.port = 443 end
		else
			conn = copas.wrap(socket.tcp())
		end
		-- copas.http applies its module-wide TIMEOUT; this request's wins.
		local timeout = p.timeout
		conn.settimeout = function(self) return copas.settimeout(self.socket, timeout) end
		return conn
	end
end

--- An error message without the `file.lua:123:` prefixes Lua errors pick up on
-- the way out of copas and LuaSec (pure).
-- @tparam any err
-- @treturn string
function M.clean_error(err)
	local s = tostring(err)
	repeat
		local before = s
		s = s:gsub("^[^\n]-%.lua:%d+: ", "", 1)
	until s == before
	return s
end

-- One request/response exchange, without redirects.
local function exchange(p, url)
	local ltn12 = require("ltn12")
	local socket = require("socket")
	local chunks = {}
	local reqt = {
		url = url, method = p.method, headers = p.headers, redirect = false,
		sink = limited_sink(chunks, p.max_bytes),
		source = p.body and ltn12.source.string(p.body) or nil,
	}

	local async = require("core.lib.async")
	local ok, code, headers
	if async.available and async.copas.running then
		local chttp = async.http
		local params
		if p.scheme == "https" then
			local err
			params, err = tls_params(p)
			if not params then return nil, err end
		end
		reqt.create = M.connector(p, async.copas, socket, params)
		local res = { pcall(chttp.request, reqt) }
		if not res[1] then return nil, tostring(res[2]) end
		ok, code, headers = res[2], res[3], res[4]
	else
		-- No scheduler: a blocking request with the same checks and timeout.
		if p.scheme == "https" then
			local https = require("core.lib.https")
			local saved = https.TIMEOUT
			https.TIMEOUT = p.timeout
			reqt.verify, reqt.cafile = p.verify, p.cafile
			ok, code, headers = https.request(reqt)
			https.TIMEOUT = saved
		else
			local http = require("socket.http")
			local saved = http.TIMEOUT
			http.TIMEOUT = p.timeout
			local res = { pcall(http.request, reqt) }
			http.TIMEOUT = saved
			if not res[1] then return nil, tostring(res[2]) end
			ok, code, headers = res[2], res[3], res[4]
		end
	end
	if not ok then return nil, tostring(code or "request failed") end
	if type(code) ~= "number" then return nil, tostring(code) end
	return { status = code, headers = headers or {}, body = table.concat(chunks) }
end

--- Make a request. Call it inside a task (`core.lib.async.run`, or through
-- `HostAPI:http`, which does that for you); outside one it blocks.
-- @tparam table req see the module doc
-- @treturn[1] table the response
-- @treturn[2] nil
-- @treturn[2] string what went wrong
function M.request(req)
	local p, err = M.prepare(req)
	if not p then return nil, err end
	local url = p.url
	for _ = 0, M.MAX_REDIRECTS do
		local res, xerr = exchange(p, url)
		if not res then return nil, M.clean_error(xerr) end
		local follow = (p.method == "GET" or p.method == "HEAD")
			and (res.status == 301 or res.status == 302 or res.status == 303
				or res.status == 307 or res.status == 308)
		if not follow then
			res.url = url
			res.ok = res.status >= 200 and res.status < 300
			return setmetatable(res, Response)
		end
		local target, why = M.redirect_target(url, res.headers.location)
		if not target then return nil, why end
		url = target
		p.scheme = url:match("^(%a+)://"):lower()
	end
	return nil, "too many redirects"
end

return M
