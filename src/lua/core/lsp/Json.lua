--- JSON for the language-server client.
--
-- Decoding is `cjson`. Encoding is done here because the protocol needs two
-- things the vendored `cjson` cannot say: an **empty array** (an empty Lua table
-- encodes as `{}`, and a server reading `"workspaceFolders": {}` is right to
-- complain) and a guarantee that an integer never leaves as `1e+15` or `3.0`.
--
-- @module core.lsp.Json
local M = {}

local ok_cjson, cjson = pcall(require, "cjson")
if not ok_cjson then cjson = nil end

--- JSON `null`. The same value `decode` produces for a `null`.
M.null = cjson and cjson.null or setmetatable({}, { __tostring = function() return "null" end })

local ARRAY = { __jsonarray = true }

--- Mark a table as a JSON array, so it encodes as `[]` even when empty.
-- @tparam[opt] table list
-- @treturn table the same table
function M.array(list)
	return setmetatable(list or {}, ARRAY)
end

--- Is `value` JSON null (or absent)?
function M.isNull(value)
	return value == nil or value == M.null
end

local ESCAPES = {
	['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
	["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}

local function escape_char(ch)
	return ESCAPES[ch] or string.format("\\u%04x", string.byte(ch))
end

local function encode_string(value)
	return '"' .. value:gsub('[%z\1-\31"\\\127]', escape_char) .. '"'
end

local function is_array(value)
	if getmetatable(value) == ARRAY then return true end
	local n = #value
	if n == 0 then return false end
	-- A sequence and nothing else: every key is 1..n.
	local count = 0
	for _ in pairs(value) do
		count = count + 1
		if count > n then return false end
	end
	return count == n
end

local encode_value

local function encode_table(value, out, depth)
	if depth > 64 then error("JSON value is nested too deeply") end
	if is_array(value) then
		out[#out + 1] = "["
		for i = 1, #value do
			if i > 1 then out[#out + 1] = "," end
			encode_value(value[i], out, depth + 1)
		end
		out[#out + 1] = "]"
		return
	end
	-- Sorted keys: the same message always serializes the same way, which is
	-- what makes a transcript comparable in a test.
	local keys = {}
	for key in pairs(value) do
		if type(key) ~= "string" then
			error("JSON object keys must be strings, got " .. type(key))
		end
		keys[#keys + 1] = key
	end
	table.sort(keys)
	out[#out + 1] = "{"
	for i, key in ipairs(keys) do
		if i > 1 then out[#out + 1] = "," end
		out[#out + 1] = encode_string(key)
		out[#out + 1] = ":"
		encode_value(value[key], out, depth + 1)
	end
	out[#out + 1] = "}"
end

function encode_value(value, out, depth)
	local kind = type(value)
	if value == M.null or value == nil then
		out[#out + 1] = "null"
	elseif kind == "string" then
		out[#out + 1] = encode_string(value)
	elseif kind == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			error("JSON cannot represent " .. tostring(value))
		end
		if value % 1 == 0 and value > -1e15 and value < 1e15 then
			out[#out + 1] = string.format("%d", value)
		else
			out[#out + 1] = string.format("%.14g", value)
		end
	elseif kind == "boolean" then
		out[#out + 1] = value and "true" or "false"
	elseif kind == "table" then
		encode_table(value, out, depth)
	else
		error("JSON cannot represent a " .. kind)
	end
end

--- Encode a Lua value.
-- @return[1] string
-- @return[2] nil
-- @return[2] string why it could not be encoded
function M.encode(value)
	local out = {}
	local ok, err = pcall(encode_value, value, out, 0)
	if not ok then return nil, tostring(err) end
	return table.concat(out)
end

--- Decode JSON text. `null` becomes `Json.null`.
-- @return[1] the value
-- @return[2] nil
-- @return[2] string why it is not valid JSON
function M.decode(text)
	if not cjson then return nil, "cjson is unavailable" end
	local ok, value = pcall(cjson.decode, text)
	if not ok then return nil, tostring(value) end
	return value
end

return M
