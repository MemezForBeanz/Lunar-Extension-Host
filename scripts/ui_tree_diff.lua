-- scripts/ui_tree_diff.lua -- compare two layout dumps (.tree files from scripts/ui_capture.lua).
--
--   luajit scripts/ui_tree_diff.lua <iup.tree> <imgui.tree> [tolerance_px]
--
-- Prints the visible elements whose rectangle differs by more than the tolerance, and the
-- ones only one build shows, in tree order.
local a_path, b_path, tol = arg[1], arg[2], tonumber(arg[3]) or 1
local function load(path)
	local list, by = {}, {}
	for line in io.lines(path) do
		local t = {}
		for field in (line .. "\t"):gmatch("([^\t]*)\t") do t[#t + 1] = field end
		local e = { path = t[1], class = t[2], x = tonumber(t[3]), y = tonumber(t[4]), w = tonumber(t[5]), h = tonumber(t[6]), label = t[7] or "" }
		list[#list + 1] = e
		by[e.path] = e
	end
	return list, by
end
local A, ai = load(a_path)
local B, bi = load(b_path)
local function short(p) return (p:gsub("^dialog", ""):gsub("(%a+)%[(%d+)%]", "%1%2")) end
local n = 0
for _, a in ipairs(A) do
	local b = bi[a.path]
	if not b then
		print("only IUP   " .. short(a.path) .. " " .. a.class .. " " .. a.label); n = n + 1
	elseif math.abs(a.x - b.x) > tol or math.abs(a.y - b.y) > tol or math.abs(a.w - b.w) > tol or math.abs(a.h - b.h) > tol then
		print(string.format("rect       %s %s IUP %d,%d %dx%d ImGui %d,%d %dx%d %s", short(a.path), a.class, a.x, a.y, a.w, a.h, b.x, b.y, b.w, b.h, a.label))
		n = n + 1
	end
end
for _, b in ipairs(B) do
	if not ai[b.path] then print("only ImGui " .. short(b.path) .. " " .. b.class .. " " .. b.label); n = n + 1 end
end
print(n .. " differences")
