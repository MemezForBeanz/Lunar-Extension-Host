--- LDoc filter that writes the API reference as GitHub wiki pages (Markdown).
--
-- Used by scripts/build_wiki.sh:
--   LUNAR_WIKI_OUT=<dir> ldoc -c config.ld --filter ldoc_wiki.run .
-- (with scripts/ on LUA_PATH). Writes one page per module, `API-<module>.md`,
-- and `API-Reference.md`, the index grouped by kind. LDoc's own HTML output
-- (`scripts/dev.sh docs`) is unchanged.

local M = {}

local KIND_TITLES = {
	module = "Modules", classmod = "Classes", topic = "Topics",
	script = "Scripts", example = "Examples", file = "Files",
}
local KIND_ORDER = { "module", "classmod", "script", "file" }

local function page_name(mod_name) return "API-" .. mod_name end

local function write(path, text)
	local f = assert(io.open(path, "wb"))
	f:write(text)
	f:close()
end

local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

-- LDoc keeps @{ref} links and backticked names in its text; render refs as code.
local function md(s)
	s = trim(tostring(s or ""):gsub("\n ", "\n"))
	s = s:gsub("@{([^}|]+)|([^}]+)}", "`%2`"):gsub("@{([^}]+)}", "`%1`")
	return s
end

local function type_of(item, group, name_or_index)
	local m = item.modifiers and item.modifiers[group]
	local e = m and m[name_or_index]
	local t = type(e) == "table" and e.type or nil
	return t and ("`" .. t .. "`") or nil
end

local function param_desc(item, name)
	local p = item.params
	if not p then return "" end
	if type(p.map) == "table" and p.map[name] then return md(p.map[name]) end
	if type(p[name]) == "string" then return md(p[name]) end
	return ""
end

local function render_item(item, out)
	local sig = item.name .. (item.args or "")
	out[#out + 1] = "### `" .. sig .. "`"
	out[#out + 1] = ""
	local text = md(item.summary)
	local desc = md(item.description)
	if desc ~= "" then text = text .. (text ~= "" and "\n\n" or "") .. desc end
	if text ~= "" then out[#out + 1] = text; out[#out + 1] = "" end
	if item.params and #item.params > 0 then
		out[#out + 1] = "**Parameters**"
		out[#out + 1] = ""
		local function line(name, indent)
			local t = type_of(item, "param", name)
			local d = param_desc(item, name)
			out[#out + 1] = indent .. "- `" .. name .. "`" .. (t and (" " .. t) or "") .. (d ~= "" and (": " .. d) or "")
		end
		for _, name in ipairs(item.params) do
			line(name, "")
			local sub = item.subparams and item.subparams[name]
			if type(sub) == "table" then
				for _, field in ipairs(sub) do line(field, "  ") end
			end
		end
		out[#out + 1] = ""
	end
	if item.ret and #item.ret > 0 then
		out[#out + 1] = "**Returns**"
		out[#out + 1] = ""
		for i, r in ipairs(item.ret) do
			local t = type_of(item, "return", i)
			local d = type(r) == "string" and md(r) or ""
			out[#out + 1] = "- " .. (t or "") .. ((t and d ~= "") and ": " or "") .. d
		end
		out[#out + 1] = ""
	end
	local usage = item.tags and item.tags.usage
	if usage then
		out[#out + 1] = "**Usage**"
		out[#out + 1] = ""
		out[#out + 1] = "```lua"
		out[#out + 1] = trim(type(usage) == "table" and table.concat(usage, "\n") or usage)
		out[#out + 1] = "```"
		out[#out + 1] = ""
	end
end

function M.run(module_list)
	local dir = assert(os.getenv("LUNAR_WIKI_OUT"), "set LUNAR_WIKI_OUT")
	local by_kind = {}
	for mod in module_list:iter() do
		if mod.type ~= "topic" and mod.type ~= "example" then
			local out = { "# " .. mod.name, "" }
			local s = md(mod.summary)
			local d = md(mod.description)
			if s ~= "" then out[#out + 1] = s; out[#out + 1] = "" end
			if d ~= "" then out[#out + 1] = d; out[#out + 1] = "" end
			local count = 0
			for item in mod.items:iter() do
				count = count + 1
				render_item(item, out)
			end
			if count == 0 and s == "" and d == "" then out[#out + 1] = "_No documented items._" end
			out[#out + 1] = ""
			out[#out + 1] = "[← API Reference](API-Reference)"
			write(dir .. "/" .. page_name(mod.name) .. ".md", table.concat(out, "\n") .. "\n")
			local list = by_kind[mod.type] or {}
			by_kind[mod.type] = list
			list[#list + 1] = mod
		end
	end
	local idx = { "# API Reference", "",
		"Generated from the source by LDoc on every push to `main`. The guides are in the sidebar.", "" }
	local kinds = {}
	for _, k in ipairs(KIND_ORDER) do if by_kind[k] then kinds[#kinds + 1] = k end end
	for k in pairs(by_kind) do
		local known = false
		for _, o in ipairs(KIND_ORDER) do if o == k then known = true end end
		if not known then kinds[#kinds + 1] = k end
	end
	for _, k in ipairs(kinds) do
		local list = by_kind[k]
		table.sort(list, function(a, b) return a.name < b.name end)
		idx[#idx + 1] = "## " .. (KIND_TITLES[k] or k)
		idx[#idx + 1] = ""
		for _, mod in ipairs(list) do
			local s = md(mod.summary):gsub("\n.*", "")
			idx[#idx + 1] = "- [" .. mod.name .. "](" .. page_name(mod.name) .. ")" .. (s ~= "" and (": " .. s) or "")
		end
		idx[#idx + 1] = ""
	end
	write(dir .. "/API-Reference.md", table.concat(idx, "\n"))
end

return M
