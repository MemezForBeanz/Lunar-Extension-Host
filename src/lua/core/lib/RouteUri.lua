--- Serializer and parser for `lunar://` route URIs.
-- Route URIs are the mechanism by which extensions and the host address
-- each other's registered handlers. The scheme is `lunar`; the authority is
-- `host` or `plugin`; the path identifies the target and, optionally, an
-- action sub-path. Query parameters carry arbitrary
-- string-valued arguments.
--
-- **URI form**: `lunar://{host|plugin}/{target}[/{action}][?key=value&...]`
--
-- All path segments and parameter names are restricted to letters, digits,
-- `.`, `_`, and `-`. Parameter values are percent-encoded using standard
-- RFC-3986 encoding; control characters are rejected in both segments and
-- decoded parameter values.
-- @module core.lib.RouteUri
-- @usage
-- local RouteUri = require("core.lib.RouteUri")
-- local uri = RouteUri.serialize{
--     kind = "plugin", target = "rom-validator", action = "run"
-- }
-- -- uri == "lunar://plugin/rom-validator/run"
-- local route = RouteUri.parse(uri)

local M = {}

local SCHEME = "lunar"
local SEGMENT_PATTERN = "^[A-Za-z0-9._%-]+$"
local KEY_PATTERN = "^[A-Za-z0-9._%-]+$"

local function trim(value)
	if type(value) ~= "string" then
		return nil
	end
	value = value:gsub("^%s+", ""):gsub("%s+$", "")
	if value == "" then
		return nil
	end
	return value
end

local function contains_control(value)
	return type(value) == "string" and value:find("[%z\001-\031]") ~= nil
end

local function pct_encode(value)
	value = tostring(value)
	return (value:gsub("([^A-Za-z0-9%-%._~])", function(ch)
		return string.format("%%%02X", string.byte(ch))
	end))
end

local function pct_decode(value)
	if value:find("%%[^0-9A-Fa-f]") or value:find("%%$") or value:find("%%[0-9A-Fa-f]$") then
		return nil, "invalid percent escape"
	end
	local ok, decoded = pcall(function()
		return (value:gsub("%%(%x%x)", function(hex)
			return string.char(tonumber(hex, 16))
		end))
	end)
	if not ok or contains_control(decoded) then
		return nil, "decoded route contains control characters"
	end
	return decoded
end

local function validate_segment(value, label)
	value = trim(value)
	if not value or not value:match(SEGMENT_PATTERN) then
		return nil, label .. " must use letters, digits, '.', '_' or '-'"
	end
	return value
end

local function normalize_params(params)
	local out = {}
	for k, v in pairs(params or {}) do
		local key = trim(k)
		if not key or not key:match(KEY_PATTERN) then
			return nil, "route parameter names must use letters, digits, '.', '_' or '-'"
		end
		if v ~= nil then
			local value = tostring(v)
			if contains_control(value) then
				return nil, "route parameter values cannot contain control characters"
			end
			out[key] = value
		end
	end
	return out
end

--- Serialize a route descriptor to a `lunar://` URI string.
-- @tparam table route route descriptor.
-- @tparam string route.kind `"host"` or `"plugin"`.
-- @tparam string route.target target name (letters, digits, `.`, `_`, `-`).
-- @tparam[opt] string route.action optional action sub-path segment.
-- @tparam[opt] table route.params key-value query parameters (values coerced to string).
-- @treturn[1] string the serialized `lunar://` URI.
-- @treturn[2] nil on validation error.
-- @treturn[2] string error message.
-- @usage
-- local uri, err = RouteUri.serialize{
--     kind = "plugin", target = "rom-validator", action = "run",
--     params = { preset = "full" }
-- }
-- -- uri == "lunar://plugin/rom-validator/run?preset=full"
function M.serialize(route)
	if type(route) ~= "table" then
		return nil, "route must be a table"
	end

	local kind = trim(route.kind)
	local params, params_err = normalize_params(route.params)
	if not params then
		return nil, params_err
	end

	local authority
	local parts = {}
	if kind == "host" then
		authority = "host"
		local target, target_err = validate_segment(route.target, "host target")
		if not target then
			return nil, target_err
		end
		parts[#parts + 1] = target
		if route.action ~= nil then
			local action, action_err = validate_segment(route.action, "host action")
			if not action then
				return nil, action_err
			end
			parts[#parts + 1] = action
		end
	elseif kind == "plugin" then
		authority = "plugin"
		local target, target_err = validate_segment(route.target, "plugin id")
		if not target then
			return nil, target_err
		end
		parts[#parts + 1] = target
		if route.action ~= nil then
			local action, action_err = validate_segment(route.action, "plugin action")
			if not action then
				return nil, action_err
			end
			parts[#parts + 1] = action
		end
	else
		return nil, "route kind must be 'host' or 'plugin'"
	end

	local query = {}
	local keys = {}
	for key in pairs(params) do
		keys[#keys + 1] = key
	end
	table.sort(keys)
	for _, key in ipairs(keys) do
		query[#query + 1] = pct_encode(key) .. "=" .. pct_encode(params[key])
	end

	local uri = SCHEME .. "://" .. authority .. "/" .. table.concat(parts, "/")
	if #query > 0 then
		uri = uri .. "?" .. table.concat(query, "&")
	end
	return uri
end

--- Parse a `lunar://` URI string into a route descriptor table.
-- Validates the scheme, authority, path segments, and percent-encoding.
-- Decoded path segments and parameter names must satisfy the same
-- character restrictions enforced by `serialize`.
-- @tparam string uri a `lunar://` URI string.
-- @treturn[1] table route descriptor: `{ kind, target, action, params }`.
--   `action` is `nil` when the URI has no action segment.
--   `params` is always a table (empty when no query string is present).
-- @treturn[2] nil on parse or validation error.
-- @treturn[2] string error message.
-- @usage
-- local route, err = RouteUri.parse("lunar://plugin/rom-validator/run?preset=full")
-- -- route == { kind="plugin", target="rom-validator", action="run", params={preset="full"} }
function M.parse(uri)
	if type(uri) ~= "string" then
		return nil, "route URI must be a string"
	end
	local scheme, authority, rest = uri:match("^([%a][%w+.-]*)://([^/?#]+)(.*)$")
	scheme = scheme and scheme:lower()
	if not scheme or scheme ~= SCHEME then
		return nil, "route URI must start with lunar://"
	end
	if authority ~= "host" and authority ~= "plugin" then
		return nil, "route authority must be host or plugin"
	end

	local path, query = rest:match("^([^?]*)%??(.*)$")
	local segments = {}
	for segment in (path or ""):gmatch("/([^/]+)") do
		local decoded, dec_err = pct_decode(segment)
		if not decoded then
			return nil, dec_err
		end
		if not decoded:match(SEGMENT_PATTERN) then
			return nil, "route path segments must use letters, digits, '.', '_' or '-'"
		end
		segments[#segments + 1] = decoded
	end

	local route = {
		kind = authority == "host" and "host" or "plugin",
		target = segments[1],
		action = segments[2],
		params = {},
	}

	if not route.target then
		return nil, "route is missing a target"
	end
	if #segments > 2 then
		return nil, "route has too many path segments"
	end

	if query and query ~= "" then
		for pair in query:gmatch("[^&]+") do
			local raw_key, raw_value = pair:match("^([^=]+)=(.*)$")
			if not raw_key then
				return nil, "route query parameters must use key=value form"
			end
			local key, key_err = pct_decode(raw_key)
			if not key then
				return nil, key_err
			end
			if not key:match(KEY_PATTERN) then
				return nil, "route parameter names must use letters, digits, '.', '_' or '-'"
			end
			local value, value_err = pct_decode(raw_value)
			if not value then
				return nil, value_err
			end
			route.params[key] = value
		end
	end

	return route
end

return M
