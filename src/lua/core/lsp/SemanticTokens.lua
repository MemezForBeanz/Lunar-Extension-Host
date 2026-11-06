--- Decode relative LSP tokens without widgets or a running server.
local Documents = require("core.lsp.Documents")
local M = {}

M.TYPES = { "namespace", "type", "class", "enum", "interface", "struct", "typeParameter", "parameter",
	"variable", "property", "enumMember", "event", "function", "method", "macro", "keyword", "modifier",
	"comment", "string", "number", "regexp", "operator", "decorator" }
M.MODIFIERS = { "declaration", "definition", "readonly", "static", "deprecated", "abstract", "async",
	"modification", "documentation", "defaultLibrary" }
M.ROLES = { namespace = "type", type = "type", class = "type", enum = "type", interface = "type", struct = "type",
	typeParameter = "type", parameter = "property", variable = "text", property = "property", enumMember = "number",
	event = "property", ["function"] = "property", method = "property", macro = "preprocessor", keyword = "keyword",
	modifier = "keyword", comment = "comment", string = "string", number = "number", regexp = "string",
	operator = "operator", decorator = "preprocessor" }

local function uint(n)
	return type(n) == "number" and n >= 0 and n == math.floor(n) and n < 4294967296
end

--- `data` contains five integers per token; deltas on a new line reset the column.
function M.decode(data, legend, text, encoding)
	if type(data) ~= "table" or #data % 5 ~= 0 then return nil, "Invalid semantic token data" end
	if type(legend) ~= "table" or type(legend.tokenTypes) ~= "table" then return nil, "Missing semantic token legend" end
	if legend.tokenModifiers ~= nil and type(legend.tokenModifiers) ~= "table" then return nil, "Invalid semantic token modifiers" end
	local lines, offsets, offset = {}, {}, 0
	for line in ((text or "") .. "\n"):gmatch("([^\n]*)\n") do
		lines[#lines + 1], offsets[#offsets + 1] = line:gsub("\r$", ""), offset
		offset = offset + #line + 1
	end
	local out, line, column = {}, 0, 0
	for i = 1, #data, 5 do
		for j = i, i + 4 do if not uint(data[j]) then return nil, "Invalid semantic token integer" end end
		local delta, start, length, kind, mask = unpack(data, i, i + 4)
		line = line + delta
		column = delta == 0 and column + start or start
		local name = legend.tokenTypes[kind + 1]
		if type(name) ~= "string" or length == 0 or not lines[line + 1] then return nil, "Semantic token outside document or legend" end
		local contents = lines[line + 1]
		local from = Documents.characterToByte(contents, column, encoding)
		local to = Documents.characterToByte(contents, column + length, encoding)
		local modifiers = {}
		for bit, modifier in ipairs(legend.tokenModifiers or {}) do
			if math.floor(mask / 2 ^ (bit - 1)) % 2 == 1 then modifiers[#modifiers + 1] = modifier end
		end
		if to > from then out[#out + 1] = { start = offsets[line + 1] + from, length = to - from,
			line = line, column = from, token_type = name, modifiers = modifiers, role = M.ROLES[name] or "text" } end
	end
	return out
end

--- Apply a `semanticTokens/full/delta` edit list to a previous integer array.
function M.applyDelta(previous, edits)
	if type(previous) ~= "table" or type(edits) ~= "table" then return nil, "Invalid semantic token edits" end
	local out, cursor = {}, 0
	for _, edit in ipairs(edits) do
		if type(edit) ~= "table" or not uint(edit.start) or not uint(edit.deleteCount)
			or edit.start < cursor or edit.start + edit.deleteCount > #previous
			or (edit.data ~= nil and type(edit.data) ~= "table") then return nil, "Invalid semantic token edit" end
		for i = cursor + 1, edit.start do out[#out + 1] = previous[i] end
		for _, n in ipairs(edit.data or {}) do
			if not uint(n) then return nil, "Invalid semantic token integer" end
			out[#out + 1] = n
		end
		cursor = edit.start + edit.deleteCount
	end
	for i = cursor + 1, #previous do out[#out + 1] = previous[i] end
	return out
end

return M
