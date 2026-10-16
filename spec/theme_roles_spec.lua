-- Every THEMEROLE core sets must exist in both rule sets.
--
-- An unknown role is not an error anywhere: the widget is simply left unstyled,
-- so a renamed or misspelled role only shows up as a wrong-looking control. This
-- reads the source for literal roles and checks them against what the Carbon and
-- Fluent builders produce.

local lfs = require("lfs")

local SRC = "src/lua/core"

local function lua_files(dir, out)
	for name in lfs.dir(dir) do
		if name ~= "." and name ~= ".." then
			local path = dir .. "/" .. name
			local mode = lfs.attributes(path, "mode")
			if mode == "directory" then
				lua_files(path, out)
			elseif name:match("%.lua$") then
				out[#out + 1] = path
			end
		end
	end
	return out
end

-- role -> first file that uses it
local function roles_in_source()
	local roles = {}
	for _, path in ipairs(lua_files(SRC, {})) do
		local f = assert(io.open(path, "r"))
		local text = f:read("*a")
		f:close()
		for role in text:gmatch('THEMEROLE%s*=%s*"([%w_]+)"') do roles[role] = roles[role] or path end
		for role in text:gmatch('themerole%s+or%s+"([%w_]+)"') do roles[role] = roles[role] or path end
		-- Roles chosen from a table at runtime (Toast's per-kind bars and backgrounds).
		for role in text:gmatch('=%s*"(toast_ba?[rg]_[%w_]+)"') do roles[role] = roles[role] or path end
	end
	return roles
end

-- Every palette key reads as a placeholder string, which is all the builders need.
local palette = setmetatable({}, { __index = function(_, k) return "<" .. k .. ">" end })

describe("theme roles", function()
	local used = roles_in_source()

	it("finds the roles core uses", function()
		assert.is_truthy(used.primary_btn)
		assert.is_truthy(used.list_bordered)
	end)

	for _, builder in ipairs({ "carbon_rules", "fluent_rules" }) do
		it("are all defined by " .. builder, function()
			local rules = require("core.classes.Themes." .. builder).build(palette)
			local missing = {}
			for role, path in pairs(used) do
				if rules[role] == nil then missing[#missing + 1] = role .. " (" .. path .. ")" end
			end
			table.sort(missing)
			assert.are.same({}, missing)
		end)
	end
end)
