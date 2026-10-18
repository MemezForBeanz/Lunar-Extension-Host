--- HTTPS requests that authenticate the server: certificate chain **and** host name.
--
-- LuaSec's own `ssl.https` defaults to `verify = "none"` and, even with
-- `verify = "peer"`, never checks that the certificate was issued for the host
-- being contacted, so any certificate signed by a trusted CA would be accepted.
-- This module performs the same connect sequence as LuaSec's `https.lua`
-- (connect, wrap, SNI, handshake) and then matches the peer certificate's
-- subjectAltName DNS/IP entries (or, only when it has none, its common name)
-- against the requested host.
--
-- `request` takes the same table as `socket.http.request`, plus the LuaSec
-- fields `verify` (`"peer"` default, or `"none"`), `cafile`, `protocol` and
-- `options`. With `verify = "none"` the connection is encrypted but not
-- authenticated, and the host name is not checked either.
--
-- @module core.lib.https

local M = {}

M.TIMEOUT = 60

local DEFAULTS = {
	protocol = "any",
	options = { "all", "no_sslv2", "no_sslv3", "no_tlsv1", "no_tlsv1_1" },
	verify = "peer",
}

local SEP = package.config:sub(1, 1)

--- The CA bundle shipped next to the executable (`certs/cacert.pem`), or nil.
-- @treturn string|nil
function M.bundled_cafile()
	local ok, dir = pcall(function() return require("core.platform").exe_dir() end)
	if not ok then return nil end
	local path = dir .. SEP .. "certs" .. SEP .. "cacert.pem"
	local f = io.open(path, "rb")
	if f then f:close() return path end
	return nil
end

local function is_ipv4(host)
	local a, b, c, d = host:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
	if not a then return false end
	for _, n in ipairs({ a, b, c, d }) do
		if tonumber(n) > 255 then return false end
	end
	return true
end

-- Canonical form of an IPv6 address (eight zero-padded lowercase groups), or nil
-- when `s` isn't one. Handles `::` compression and an embedded IPv4 tail, so two
-- spellings of the same address compare equal.
local function ipv6_canonical(s)
	if type(s) ~= "string" or not s:find(":", 1, true) then return nil end
	s = s:lower():gsub("%%.*$", "")  -- drop a zone id
	local head, v4 = s:match("^(.*:)(%d+%.%d+%.%d+%.%d+)$")
	if v4 then
		if not is_ipv4(v4) then return nil end
		local a, b, c, d = v4:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
		s = head .. string.format("%x:%x", a * 256 + b, c * 256 + d)
	end
	local function split(str)
		local t = {}
		if str == "" then return t end
		for g in (str .. ":"):gmatch("([^:]*):") do
			if not g:match("^%x%x?%x?%x?$") then return nil end
			t[#t + 1] = g
		end
		return t
	end
	local groups
	local left, right = s:match("^(.-)::(.-)$")
	if left then
		local l, r = split(left), split(right)
		if not l or not r or #l + #r > 7 then return nil end
		groups = l
		for _ = 1, 8 - #l - #r do groups[#groups + 1] = "0" end
		for _, g in ipairs(r) do groups[#groups + 1] = g end
	else
		groups = split(s)
		if not groups or #groups ~= 8 then return nil end
	end
	for i, g in ipairs(groups) do groups[i] = string.format("%04x", tonumber(g, 16)) end
	return table.concat(groups, ":")
end

-- RFC 6125: a wildcard stands for exactly one left-most label, and never matches
-- a bare public suffix ("*.com"). Callers only pass DNS names here, never IPs.
local function dns_matches(pattern, host)
	pattern = pattern:lower():gsub("%.$", "")
	if pattern == host then return true end
	local suffix = pattern:match("^%*(%..+)$")
	if not suffix or not suffix:find(".", 2, true) then return false end
	local first_label = host:match("^([^.]+)%..+$")
	return first_label ~= nil and host:sub(#first_label + 1) == suffix
end

local function as_list(v)
	if type(v) == "table" then return v end
	if v == nil then return {} end
	return { v }
end

--- Does the certificate cover `host`?
-- The host is first classified as an IPv4 address, an IPv6 address or a DNS name
-- (after removing `[...]` and a trailing dot), and only compared against the
-- matching kind of certificate entry: an IP never matches a DNS name entry.
-- Pure function over a LuaSec X.509 object (anything with `extensions()` and
-- `subject()`), so it can be tested without a network.
-- @param cert Peer certificate.
-- @tparam string host Host name or IP address from the URL.
-- @treturn boolean
function M.certificate_matches(cert, host)
	if not cert or type(host) ~= "string" then return false end
	host = host:gsub("^%[(.*)%]$", "%1"):gsub("%.$", ""):lower()
	if host == "" then return false end
	local v6 = ipv6_canonical(host)
	local kind = is_ipv4(host) and "ipv4" or (v6 and "ipv6") or "dns"

	local function ip_equal(entry)
		if type(entry) ~= "string" then return false end
		if kind == "ipv4" then return entry == host end
		return ipv6_canonical(entry) == v6
	end

	local ok_ext, exts = pcall(cert.extensions, cert)
	local san = ok_ext and type(exts) == "table" and exts["2.5.29.17"] or nil
	if san then
		if kind == "dns" then
			for _, name in ipairs(as_list(san.dNSName)) do
				if type(name) == "string" and dns_matches(name, host) then return true end
			end
		else
			for _, ip in ipairs(as_list(san.iPAddress)) do
				if ip_equal(ip) then return true end
			end
		end
		return false
	end
	-- No subjectAltName at all: fall back to the subject common name.
	local ok_sub, subject = pcall(cert.subject, cert)
	if ok_sub and type(subject) == "table" then
		for _, entry in ipairs(subject) do
			if (entry.name == "commonName" or entry.oid == "2.5.4.3") and type(entry.value) == "string" then
				if kind == "dns" then return dns_matches(entry.value, host) end
				return ip_equal(entry.value)
			end
		end
	end
	return false
end
-- LuaSocket `create` function doing LuaSec's TLS connect, then the host check.
local function make_create(params, try, socket, ssl)
	return function()
		local conn = { sock = try(socket.tcp()) }
		function conn:settimeout(t)
			return self.sock:settimeout(t or M.TIMEOUT)
		end
		function conn:connect(host, port)
			try(self.sock:connect(host, port))
			self.sock = try(ssl.wrap(self.sock, params))
			self.sock:sni(host)
			self.sock:settimeout(M.TIMEOUT)
			try(self.sock:dohandshake())
			if params.verify ~= "none" then
				local cert = self.sock:getpeercertificate()
				if not M.certificate_matches(cert, host) then
					self.sock:close()
					try(nil, "certificate is not valid for host " .. host)
				end
			end
			-- Forward the remaining socket methods (send, receive, close, ...).
			local mt = getmetatable(self.sock).__index
			for name, method in pairs(mt) do
				if type(method) == "function" and self[name] == nil then
					self[name] = function(s, ...) return method(s.sock, ...) end
				end
			end
			return 1
		end
		return conn
	end
end

--- Perform an HTTPS request with server authentication.
-- @tparam table reqt A `socket.http.request` table (`url`, `method`, `headers`,
--   `source`, `sink`, ...) plus optional `verify`, `cafile`, `protocol`, `options`.
-- @return Same as `socket.http.request`: `1, code, headers, status` or `nil, err`.
function M.request(reqt)
	local http = require("socket.http")
	local socket = require("socket")
	local ssl = require("ssl")
	local url = require("socket.url")

	if type(reqt) ~= "table" or type(reqt.url) ~= "string" then
		return nil, "https.request expects a request table with a url"
	end
	local parsed = url.parse(reqt.url)
	if not parsed or parsed.scheme ~= "https" then
		return nil, "https.request needs an https:// URL"
	end
	if reqt.proxy or http.PROXY then return nil, "proxy not supported" end

	local params = { mode = "client" }
	for k, v in pairs(DEFAULTS) do params[k] = v end
	for _, k in ipairs({ "protocol", "options", "verify", "cafile", "capath", "certificate", "key" }) do
		if reqt[k] ~= nil then params[k] = reqt[k] end
	end
	if params.verify ~= "none" and not params.cafile and not params.capath then
		params.cafile = M.bundled_cafile()
		if not params.cafile then
			return nil, "no trust store: set a CA file or ship certs/cacert.pem"
		end
	end

	local out = {}
	for k, v in pairs(reqt) do out[k] = v end
	out.create = make_create(params, socket.try, socket, ssl)
	out.redirect = false
	-- socket.http hands its own TIMEOUT to the connection; use ours instead, the
	-- way LuaSec's https module does, so callers set `https.TIMEOUT`.
	local saved = http.TIMEOUT
	http.TIMEOUT = M.TIMEOUT
	local res = { pcall(http.request, out) }
	http.TIMEOUT = saved
	if not res[1] then return nil, tostring(res[2]) end
	return unpack(res, 2, 5)
end

return M
