--- HTTP client for submitting structured feedback to the configured backend.
-- Sends a JSON-encoded payload to `{base_url}/feedback` via a POST request,
-- through `core.lib.http` (HTTPS checks the certificate chain and host name).
-- Call `submit` inside a task (`ctx:runAsync`) so it doesn't block the window.
-- @module core.lib.FeedbackClient
-- @usage
-- local FeedbackClient = require("core.lib.FeedbackClient")
-- local ok, err = FeedbackClient.submit("https://lunar-db.example.com", {
--     run_id = "abc123", result = "pass"
-- })

local cjson = require("cjson")

local M = {}

local function response_error(code, status, raw)
	local detail = raw
	if raw ~= "" then
		local ok, decoded = pcall(cjson.decode, raw)
		if ok and type(decoded) == "table" and decoded.detail ~= nil then
			detail = type(decoded.detail) == "string"
				and decoded.detail or cjson.encode(decoded.detail)
		end
	end
	if detail == "" then detail = status or "request rejected" end
	return string.format("feedback submission failed (HTTP %s): %s", tostring(code), detail)
end

--- Submit a feedback payload to the backend.
-- Encodes `payload` as JSON, POSTs it to `{base_url}/feedback`, and
-- returns the decoded JSON response body. Returns `true` when the server
-- responds with a 2xx status and an empty body.
-- @tparam string base_url backend root URL, e.g. `"https://lunar-db.example.com"`.
--   Must start with `http://` or `https://`.
-- @tparam table payload arbitrary table to serialize as the request body.
-- @tparam[opt] table opts options table.
-- @tparam[opt=5] number opts.timeout HTTP request timeout in seconds.
-- @tparam[opt="Lunar"] string opts.user_agent `User-Agent` header value.
-- @tparam[opt="peer"] string opts.tls_verify `"peer"` (check chain and host name)
--   or `"none"` (encrypt only). https only.
-- @tparam[opt] string opts.ca_file PEM trust file; defaults to the bundled
--   `certs/cacert.pem`.
-- @tparam[opt] table opts.transport a `socket.http`-style transport `{ http, ltn12 }`
--   used instead of `core.lib.http` (the specs' seam).
-- @treturn[1] boolean|table `true` (empty 2xx response) or decoded JSON object.
-- @treturn[2] nil on any error.
-- @treturn[2] string error message.
function M.submit(base_url, payload, opts)
	opts = opts or {}
	if type(base_url) ~= "string" or base_url == "" then
		return nil, "feedback backend URL is not configured"
	end
	if type(payload) ~= "table" then
		return nil, "feedback payload must be a table"
	end

	if not base_url:match("^[hH][tT][tT][pP][sS]?://") then
		return nil, "backend URL must start with http:// or https://"
	end
	local ok_encode, body = pcall(cjson.encode, payload)
	if not ok_encode then
		return nil, "feedback encode failed: " .. tostring(body)
	end

	local url = base_url:gsub("/+$", "") .. "/feedback"
	local headers = {
		["Accept"] = "application/json",
		["Content-Type"] = "application/json",
		["Content-Length"] = tostring(#body),
		["User-Agent"] = opts.user_agent or "Lunar",
	}
	local timeout = tonumber(opts.timeout) or 5
	local verify = opts.tls_verify == "none" and "none" or "peer"
	local cafile = (type(opts.ca_file) == "string" and opts.ca_file ~= "") and opts.ca_file or nil

	local code, status, raw
	local transport = opts.transport
	if transport then
		local response = {}
		local http = transport.http
		local saved_timeout = http.TIMEOUT
		http.TIMEOUT = timeout
		local returned = { pcall(http.request, {
			url = url, method = "POST", headers = headers,
			source = transport.ltn12.source.string(body),
			sink = transport.ltn12.sink.table(response),
			verify = verify, cafile = cafile,
		}) }
		http.TIMEOUT = saved_timeout
		if not returned[1] then return nil, "feedback transport error: " .. tostring(returned[2]) end
		if returned[2] == nil then return nil, "feedback transport error: " .. tostring(returned[3]) end
		code, status, raw = tonumber(returned[3]), returned[5], table.concat(response)
	else
		local res, err = require("core.lib.http").request({
			url = url, method = "POST", headers = headers, body = body,
			timeout = timeout, verify = verify, cafile = cafile, max_bytes = 1024 * 1024,
		})
		if not res then return nil, "feedback transport error: " .. tostring(err) end
		code, status, raw = res.status, tostring(res.status), res.body
	end

	if not code or code < 200 or code >= 300 then
		return nil, response_error(code, status, raw)
	end
	if raw == "" then return true end
	local ok_decode, decoded = pcall(cjson.decode, raw)
	if not ok_decode then
		return nil, "feedback response decode failed: " .. tostring(decoded)
	end
	return decoded
end

return M
