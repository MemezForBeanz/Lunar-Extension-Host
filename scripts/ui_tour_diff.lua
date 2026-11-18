-- scripts/ui_tour_diff.lua -- pair the two builds' scripts/ui_tour.lua runs, interface by interface.
--
--   luajit scripts/ui_tour_diff.lua <tour_dir> [tolerance_px] > report.md
--
-- For every interface key: whether each build opened it, the shot files of each build,
-- the callback errors, and (for dialogs) the elements whose rectangle differs by more
-- than the tolerance or that only one build has.
local dir, tol = arg[1] or ".", tonumber(arg[2]) or 2

local function load(build)
	local data = { order = {}, info = {}, trees = {}, errors = {} }
	local f = io.open(dir .. "/tour-" .. build .. ".tsv")
	if not f then return data end
	for line in f:lines() do
		local t = {}
		for field in (line .. "\t"):gmatch("([^\t]*)\t") do t[#t + 1] = field end
		local kind, key = t[1], t[2]
		if kind == "O" and key then
			if not data.info[key] then data.order[#data.order + 1] = key; data.info[key] = {} end
			local i = data.info[key]
			if t[4] and t[4] ~= "" or t[5] then i.page, i.path, i.label = t[3] or i.page, t[4] or i.path, t[5] or i.label end
			if #t == 3 or (t[3] and t[3]:find("dialog:") or t[3] == "popup") then i.opened = t[3] end
			if t[6] and t[6] ~= "" then i.result = t[6] end
		elseif kind == "T" then
			data.trees[key] = data.trees[key] or {}
			data.trees[key][t[3]] = { class = t[4], x = tonumber(t[5]), y = tonumber(t[6]), w = tonumber(t[7]), h = tonumber(t[8]), label = t[9] }
		elseif kind == "X" then
			data.errors[key] = data.errors[key] or {}
			table.insert(data.errors[key], t[3])
		end
	end
	f:close()
	return data
end

local function shots(build, key)
	local list = {}
	for _, suffix in ipairs({ "", "-w1", "-w2", "-w3" }) do
		local name = build .. "__" .. key .. suffix .. ".png"
		local f = io.open(dir .. "/" .. name, "rb")
		if f then f:close(); list[#list + 1] = name end
	end
	return list
end

local A, B = load("iup"), load("imgui")
local keys, seen = {}, {}
for _, d in ipairs({ A, B }) do
	for _, k in ipairs(d.order) do if not seen[k] then seen[k] = true; keys[#keys + 1] = k end end
end

print("# Interface tour: IUP vs ImGui")
print("")
print("Shots are in " .. dir .. " (iup__<key>*.png and imgui__<key>*.png).")
for _, key in ipairs(keys) do
	local a, b = A.info[key], B.info[key]
	print("")
	print("## " .. key)
	local i = a or b
	if i.page or i.label then print("- control: " .. tostring(i.page) .. " / " .. tostring(i.label) .. " `" .. tostring(i.path) .. "`") end
	print("- IUP: " .. (a and (a.opened or a.result or "shown") or "**did not open**") .. " " .. table.concat(shots("iup", key), ", "))
	print("- ImGui: " .. (b and (b.opened or b.result or "shown") or "**did not open**") .. " " .. table.concat(shots("imgui", key), ", "))
	for build, d in pairs({ IUP = A, ImGui = B }) do
		for _, e in ipairs(d.errors[key] or {}) do print("- " .. build .. " error: " .. e:sub(1, 300)) end
	end
	local ta, tb = A.trees[key], B.trees[key]
	if ta and tb then
		local diffs = {}
		for path, ea in pairs(ta) do
			local eb = tb[path]
			if not eb then
				diffs[#diffs + 1] = "only IUP: `" .. path .. "` " .. ea.class .. " " .. ea.label
			elseif ea.x and eb.x and (math.abs(ea.x - eb.x) > tol or math.abs(ea.y - eb.y) > tol
				or math.abs(ea.w - eb.w) > tol or math.abs(ea.h - eb.h) > tol) then
				diffs[#diffs + 1] = string.format("rect `%s` %s IUP %d,%d %dx%d ImGui %d,%d %dx%d %s", path, ea.class,
					ea.x, ea.y, ea.w, ea.h, eb.x, eb.y, eb.w, eb.h, ea.label)
			end
		end
		for path, eb in pairs(tb) do
			if not ta[path] then diffs[#diffs + 1] = "only ImGui: `" .. path .. "` " .. eb.class .. " " .. eb.label end
		end
		table.sort(diffs)
		if #diffs > 0 then
			print("- layout differences (" .. #diffs .. "):")
			for n = 1, math.min(#diffs, 40) do print("  - " .. diffs[n]) end
		else
			print("- layout: every element within " .. tol .. " px")
		end
	end
end
