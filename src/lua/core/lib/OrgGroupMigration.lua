-- Repair historical org group names in saved layouts, including layouts whose
-- tool_group_applied marker already records the new name.
local M = {}

function M.migrate(layout, profiles)
	if type(layout) ~= "table" then return false end
	local aliases = {}
	local microchip_group
	for _, profile in ipairs(profiles or {}) do
		if profile.id == "microchip" then
			microchip_group = profile.tool_group
			aliases["Black Duck Tools"] = profile.tool_group
			aliases["Black Duck Tools (microchip)"] = profile.tool_group
		end
	end
	local changed = false
	local function merge(into, incoming)
		into.children = into.children or {}
		for _, node in ipairs(incoming.children or {}) do
			local existing
			for _, child in ipairs(into.children) do
				if node.t == "tab" and child.t == "tab" and node.key == child.key then
					existing = child
				elseif node.t == "group" and child.t == "group"
					and node.source == "manifest" and child.source == "manifest" and node.name == child.name then
					existing = child
				end
			end
			if not existing then
				into.children[#into.children + 1] = node
			elseif node.t == "group" then
				merge(existing, node)
			end
		end
		if not into.active then into.active = incoming.active end
	end
	local function repair(nodes)
		if type(nodes) ~= "table" then return end
		local targets = {}
		for _, node in ipairs(nodes) do
			if node.t == "group" and node.source == "manifest" then
				if aliases[node.name] and aliases[node.name] ~= node.name then
					node.name = aliases[node.name]
					changed = true
				end
				-- Only consolidate the known renamed pack, not arbitrary user groups.
				for _, target in pairs(aliases) do
					if node.name == target then targets[target] = targets[target] or node end
				end
			end
		end
		for index = #nodes, 1, -1 do
			local node = nodes[index]
			local target = node.source == "manifest" and targets[node.name]
			if target and target ~= node then
				merge(target, node)
				table.remove(nodes, index)
				changed = true
			end
		end
	end
	-- Old packs supplied a Black Duck Server group inside the org group. Saved
	-- membership wins over today's flat manifest hints, so removing the hint alone
	-- cannot remove that extra navigation level.
	local obsolete = { ["Black Duck Server"] = true, ["Black Duck"] = true,
		Server = true, ["Time Clock"] = true, Timeclock = true }
	local function is_tool(node)
		return node.t == "tab" and type(node.key) == "string"
			and (node.key:match("^blackduck/") or node.key:match("^timeclock/")) ~= nil
	end
	local function has_tools(node)
		if is_tool(node) then return true end
		for _, child in ipairs(node.children or {}) do if has_tools(child) then return true end end
		return false
	end
	local function selected_tool(node)
		if is_tool(node) then return node.key end
		for _, child in ipairs(node.children or {}) do
			local key = child.t == "group" and ("group:" .. child.name) or child.key
			if key == node.active then return selected_tool(child) end
		end
	end
	local function flatten_microchip(nodes)
		if not microchip_group or type(nodes) ~= "table" then return end
		local target, legacy
		local function inspect(list)
			for _, node in ipairs(list) do
				if node.t == "group" then
					if node.source == "manifest" and obsolete[node.name] and has_tools(node) then legacy = true end
					inspect(node.children or {})
				end
			end
		end
		inspect(nodes)
		-- Only repair layouts with the retired automatic grouping. Once repaired,
		-- later toolbar moves and custom groups remain the user's arrangement.
		if not legacy then return end
		for _, node in ipairs(nodes) do
			if node.t == "group" and node.source == "manifest" and node.name == microchip_group then
				target = node
				break
			end
		end
		if not target then
			target = { t = "group", name = microchip_group, source = "manifest", children = {} }
			nodes[#nodes + 1] = target
		end
		local tools, seen, active = {}, {}, selected_tool(target)
		local function take(list)
			local kept = {}
			for _, node in ipairs(list) do
				if is_tool(node) then
					if not seen[node.key] then tools[#tools + 1] = node; seen[node.key] = true end
				elseif node.t == "group" then
					local contained = has_tools(node)
					if contained and not active then active = selected_tool(node) end
					node.children = take(node.children or {})
					if node == target or #node.children > 0 or not contained then kept[#kept + 1] = node end
				else
					kept[#kept + 1] = node
				end
			end
			return kept
		end
		local kept = take(nodes)
		-- Keep unrelated tools, including another org's group accidentally nested
		-- here, alongside Microchip rather than burying them under its four tools.
		local remaining = target.children
		target.children = tools
		if not seen[target.active] then target.active = seen[active] and active or (tools[1] and tools[1].key) end
		for i, node in ipairs(kept) do
			if node == target then
				for offset, child in ipairs(remaining) do table.insert(kept, i + offset, child) end
				break
			end
		end
		for i = #nodes, 1, -1 do nodes[i] = nil end
		for i, node in ipairs(kept) do nodes[i] = node end
		changed = true
	end
	repair(layout.children)
	flatten_microchip(layout.children)
	for _, nodes in pairs(layout.panes or {}) do repair(nodes); flatten_microchip(nodes) end
	return changed
end

return M
