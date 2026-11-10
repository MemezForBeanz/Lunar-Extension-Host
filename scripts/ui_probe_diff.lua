-- scripts/ui_probe_diff.lua -- compare two scripts/ui_probe.lua runs (IUP build vs ImGui build).
--
--   luajit scripts/ui_probe_diff.lua probe-iup.tsv probe-imgui.tsv [tolerance_px]
--
-- Reports, page by page: elements only one build has, visible elements whose rectangle
-- differs by more than the tolerance, and controls whose click fired different callbacks.
local a_path, b_path, tol = arg[1], arg[2], tonumber(arg[3]) or 2

local function load(path)
	local pages, order, page = {}, {}, nil
	local warnings = {}
	for line in io.lines(path) do
		local f = {}
		for field in (line .. "\t"):gmatch("([^\t]*)\t") do f[#f + 1] = field end
		if f[1] == "P" then
			page = { E = {}, C = {}, A = {}, order = {} }
			pages[f[2]] = page
			order[#order + 1] = f[2]
		elseif f[1] == "E" and page then
			page.E[f[2]] = { class = f[3], x = tonumber(f[4]), y = tonumber(f[5]), w = tonumber(f[6]), h = tonumber(f[7]),
				vis = f[8] == "1", label = f[9], cb = f[10] }
			page.order[#page.order + 1] = f[2]
		elseif f[1] == "A" and page then
			local set = {}
			for kv in (f[3] or ""):gmatch("[^;]+") do
				local k, v = kv:match("^([^=]+)=(.*)$")
				if k then set[k] = v end
			end
			page.A[f[2]] = set
		elseif f[1] == "C" and page then
			page.C[f[2]] = f[3] or ""
		elseif f[1] == "W" then
			warnings[#warnings + 1] = f[2]
		end
	end
	return pages, order, warnings
end

local A, order, wa = load(a_path)
local B, _, wb = load(b_path)
local canvas_paths = {}
for _, pages in ipairs({ A, B }) do
	for _, page in pairs(pages) do
		for path, e in pairs(page.E) do if e.class == "canvas" then canvas_paths[path] = true end end
	end
end

local function short(path) return (path:gsub("^dialog", ""):gsub("(%a+)%[(%d+)%]", "%1%2")) end
local function rect(e) return e.x and string.format("%d,%d %dx%d", e.x, e.y, e.w, e.h) or "-" end
-- A canvas's ACTION is its paint callback: when a click repaints it is not about the click.
local function norm_fired(s)
	local set = {}
	for item in (s or ""):gmatch("[^,]+") do
		local path, name = item:match("^(.*):([%u_]+)$")
		if not (name == "ACTION" and canvas_paths[path]) then set[item] = true end
	end
	local list = {}
	for k in pairs(set) do list[#list + 1] = short(k) end
	table.sort(list)
	return table.concat(list, " ")
end

local totals = { rect = 0, click = 0, missing = 0, attr = 0 }
-- Colours compare as numbers, so "0 0 0" and "0 0 0 255" agree.
local function same_value(a, b)
	if a == b then return true end
	local na = {} for n in tostring(a):gmatch("%d+") do na[#na + 1] = n end
	local nb = {} for n in tostring(b):gmatch("%d+") do nb[#nb + 1] = n end
	if #na >= 3 and #nb >= 3 and na[1] == nb[1] and na[2] == nb[2] and na[3] == nb[3] then return true end
	return false
end
for _, title in ipairs(order) do
	local pa, pb = A[title], B[title]
	print("== " .. title)
	if not pb then print("  page missing in " .. b_path) else
		for _, path in ipairs(pa.order) do
			local ea, eb = pa.E[path], pb.E[path]
			if not eb then
				if ea.vis then print("  only A  " .. short(path) .. " " .. ea.class .. " " .. ea.label); totals.missing = totals.missing + 1 end
			elseif ea.vis and ea.x and ea.w > 0 and ea.h > 0 then
				if not eb.vis then
					print(string.format("  hidden  %s %s A=%s %s", short(path), ea.class, rect(ea), ea.label))
					totals.rect = totals.rect + 1
				elseif not eb.x or math.abs(ea.x - eb.x) > tol or math.abs(ea.y - eb.y) > tol
					or math.abs(ea.w - eb.w) > tol or math.abs(ea.h - eb.h) > tol then
					print(string.format("  rect    %s %s A=%s B=%s %s", short(path), ea.class, rect(ea), rect(eb), ea.label))
					totals.rect = totals.rect + 1
				end
			end
		end
		for _, path in ipairs(pa.order) do
			local aa, ab = pa.A[path], pb.A[path]
			if aa and ab and pa.E[path].vis then
				local diffs = {}
				local keys = {}
				for k in pairs(aa) do keys[k] = true end
				for k in pairs(ab) do keys[k] = true end
				local sorted = {}
				for k in pairs(keys) do sorted[#sorted + 1] = k end
				table.sort(sorted)
				for _, k in ipairs(sorted) do
					if not same_value(aa[k], ab[k]) then diffs[#diffs + 1] = string.format("%s A=%s B=%s", k, tostring(aa[k]), tostring(ab[k])) end
				end
				if #diffs > 0 then
					print(string.format("  attr    %s %s: %s", short(path), pa.E[path].class, table.concat(diffs, " | ")))
					totals.attr = totals.attr + 1
				end
			end
		end
		for _, path in ipairs(pb.order) do
			if not pa.E[path] and pb.E[path].vis then
				print("  only B  " .. short(path) .. " " .. pb.E[path].class .. " " .. pb.E[path].label)
				totals.missing = totals.missing + 1
			end
		end
		local seen = {}
		for path, fa in pairs(pa.C) do
			seen[path] = true
			local fb = pb.C[path]
			if fb == nil then
				print(string.format("  noclick %s (A fired: %s)", short(path), norm_fired(fa)))
				totals.click = totals.click + 1
			elseif norm_fired(fa) ~= norm_fired(fb) then
				print(string.format("  click   %s %s\n            A: %s\n            B: %s", short(path),
					(pa.E[path] or {}).label or "", norm_fired(fa), norm_fired(fb)))
				totals.click = totals.click + 1
			end
		end
		for path, fb in pairs(pb.C) do
			if not seen[path] then
				print(string.format("  clickB  %s (B fired: %s)", short(path), norm_fired(fb)))
			end
		end
	end
end
print(string.format("\n%d rect differences, %d click differences, %d elements in one build only, %d attribute differences", totals.rect, totals.click, totals.missing, totals.attr))
local function warns(name, list)
	local count = {}
	for _, w in ipairs(list) do count[w] = (count[w] or 0) + 1 end
	local keys = {}
	for k in pairs(count) do keys[#keys + 1] = k end
	table.sort(keys)
	if #keys > 0 then print("\nwarnings " .. name) end
	for _, k in ipairs(keys) do print(string.format("  %3d %s", count[k], k:sub(1, 300))) end
end
warns(a_path, wa)
warns(b_path, wb)
