-- The drag changes the picture, not the widget tree. Commit the actual order
-- through TabOrder's deferred drop only when the mouse is released.
local E = require("core.imgui.Element")
local R = require("core.imgui.Runtime")
local iup = require("core.imgui.iup")
local motion = require("core.imgui.motion")
local Tabs = require("core.imgui.widgets.flattabs")
local M = {}
local gesture

local function vertical(el)
	local t = iup.GetAttribute(el, "TABTYPE")
	return t == "LEFT" or t == "RIGHT"
end

function M.finish()
	if not gesture then return end
	for el in pairs(gesture.strips) do
		local st = E.state(el)
		if st then
			st.data.drag_offsets, st.data.drag_source = nil, nil
			for key in pairs(st.data.motion or {}) do
				if key:match("^drag%d+$") then st.data.motion[key] = nil end
			end
		end
	end
	if gesture.overlay then gesture.overlay:close() end
	gesture = nil
	R.animate()
end

function M.start(source, pos, x, y)
	M.finish()
	if not motion.enabled() then return end
	for _, rect in ipairs(Tabs.headerRects(source)) do
		if rect.pos == pos then
			local st = E.state(source)
			local w, h = Tabs.dragSize(source, pos, rect)
			gesture = { source = source, pos = pos, w = w, h = h, slotw = rect.w, sloth = rect.h,
				grabx = (st.x + x - rect.x) * w / rect.w,
				graby = (st.y + y - rect.y) * h / rect.h, strips = {} }
			local g = gesture
			g.overlay = R.overlay{ owner = iup.GetDialog(source), draw = function(dc)
				if not gesture or not motion.enabled() or not E.state(source) or not g.x then return end
				dc:alpha_push(0.86)
				Tabs.drawDragHeader(source, pos, dc, g.x, g.y, g.w, g.h)
				dc:alpha_pop()
			end }
			return
		end
	end
end

local function offsets(g, el, remove, insert)
	local st = E.state(el)
	if not st then return end
	g.strips[el] = true
	local v = vertical(el)
	local delta, result, inserted = 0, {}, false
	local size = el == g.source and (v and g.sloth or g.slotw) or (v and g.h or g.w)
	for _, rect in ipairs(Tabs.headerRects(el)) do
		local extent = v and rect.h or rect.w
		if remove and rect.pos == g.pos then
			delta = delta - extent
		else
			if insert and not inserted and rect.pos + 1 >= insert then
				delta, inserted = delta + size, true
			end
			result[rect.pos] = delta
		end
	end
	st.data.drag_offsets = result
	st.data.drag_source = remove and g.pos or nil
end

function M.update(destination, index, combine, x, y)
	local g = gesture
	if not g then return end
	if not motion.enabled() or not E.state(g.source) then M.finish(); return end
	g.x, g.y = x - g.grabx, y - g.graby
	for el in pairs(g.strips) do
		local st = E.state(el)
		if st then st.data.drag_offsets, st.data.drag_source = {}, nil end
	end
	-- A combine keeps the target in place so its outline doesn't run away from
	-- the pointer. An insertion opens a gap and closes the source's old slot.
	if destination and not combine then
		offsets(g, g.source, true, destination == g.source and index or nil)
		if destination ~= g.source then offsets(g, destination, false, index) end
	else
		local st = E.state(g.source)
		st.data.drag_source = g.pos
		g.strips[g.source] = true
	end
	R.animate()
end

return M
