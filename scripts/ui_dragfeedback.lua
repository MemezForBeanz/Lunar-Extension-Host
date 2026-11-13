-- Run with Lunar.exe scripts/ui_dragfeedback.lua <output-directory> on a private desktop.
-- Adds disposable tabs to the real shell and holds a drag over a merge target.
-- LUNAR_DRAG_PROBE: merge (default), into, reorder, sidebar, vertical, off.
local iup = require("iup")
local R = require("core.imgui.Runtime")
local E = require("core.imgui.Element")
local ffi = require("ffi")
-- Exercise the user's appearance without persisting the disposable tab layout.
require("core.classes.SettingsManager").save = function() return true end
local mode = os.getenv("LUNAR_DRAG_PROBE") or "merge"
local outdir = assert(arg[1], "output directory required")
local out = assert(io.open(outdir .. "/drag-" .. mode .. ".txt", "w"))
local function say(...)
	local a = {}; for i = 1, select("#", ...) do a[i] = tostring(select(i, ...)) end
	out:write(table.concat(a, " "), "\n"); out:flush()
end
local Order = require("core.classes.TabOrder")
local order, feedback
local setMotion = Order.setMotion
Order.setMotion = function(self, m) order, feedback = self, m; return setMotion(self, m) end
local resolve = Order._resolveDrop
Order._resolveDrop = function(self, ...)
	local d = resolve(self, ...)
	say("drop", d and (d.merge and "merge" or d.into and "into" or "insert") or "nil",
		d and d.tab_x or "-", d and d.tab_w or "-", d and d.band or "-")
	return d
end
pcall(ffi.cdef, "int PostMessageA(void*, unsigned, uintptr_t, intptr_t);")
local user = ffi.load("user32")
local function post(msg, x, y)
	local hwnd = ffi.cast("void*", tonumber(R.backend().window("hwnd")))
	user.PostMessageA(hwnd, msg, msg == 0x202 and 0 or 1, y * 65536 + x)
end
local function find(root)
	if iup.GetClassName(root) == "flattabs" and iup.GetAttribute(root, "THEMEROLE") == "titlebar_tabs" then return root end
	for n = 0, iup.GetChildCount(root) - 1 do local h = find(iup.GetChild(root, n)); if h then return h end end
end
local loop = iup.MainLoop
iup.MainLoop = function()
	local step, view, sx, sy, tx, ty = 0
	local timer = iup.timer{ time = 100 }
	function timer:action_cb()
		step = step + 1
		local ok, err = pcall(function()
			local shell = rawget(_G, "LUNAR_DEV_SHELL")
			if step == 10 then
				local groups = shell.groups()
				local root = groups:rootStrip()
				for _, name in ipairs({ "Drag source", "Merge target" }) do
					shell.host:addTab(name, iup.vbox{ iup.label{ TITLE = name } })
					groups:setToolbar(iup.GetChild(root, iup.GetChildCount(root) - 1), "top")
				end
				if mode == "off" then feedback._director:configure({ enabled = false }) end
				if mode == "sidebar" or mode == "vertical" then
					groups:setToolbar(iup.GetChild(root, iup.GetChildCount(root) - 2), "left")
					if mode == "vertical" then groups:setToolbar(iup.GetChild(root, iup.GetChildCount(root) - 1), "left") end
					if not shell.view_layout:barsVisible() then shell.view_layout:toggleBars() end
				elseif mode == "into" then
					local group = groups:createGroup(root, "Target group")
					groups:setToolbar(group, "top")
				end
				shell.sync_title_bar()
				iup.Refresh(iup.GetDialog(root))
			elseif step == 20 then
				view = assert(find(iup.GetDialog(shell.groups():rootStrip())))
				local st = E.state(view)
				say("view", st.x, st.y, st.w, st.h)
				local spans = {}
				for x = 0, st.w - 1 do
					local p = iup.ConvertXYToPos(view, x, 12)
					if p >= 0 then spans[p] = spans[p] or { x, x }; spans[p][2] = x end
				end
				for p, span in pairs(spans) do
					local title = iup.GetAttribute(view, "TABTITLE" .. p)
					say("tab", p, title, span[1], span[2])
					if title == "Drag source" then sx = st.x + math.floor((span[1] + span[2]) / 2) end
					if title == "Merge target" then tx = st.x + math.floor((span[1] + span[2]) / 2) end
					if (mode == "reorder" or mode == "off") and title == "Merge target" then tx = st.x + span[2] - 1 end
					if mode == "into" and title == "Target group" then tx = st.x + math.floor((span[1] + span[2]) / 2) end
				end
				sy, ty = st.y + 12, st.y + 12
				if mode == "sidebar" or mode == "vertical" then
					local rail = shell.rail:widget()
					for _, rect in ipairs(require("core.imgui.widgets.flattabs").headerRects(rail)) do
						if iup.GetAttribute(rail, "TABTITLE" .. rect.pos) == "Drag source" then
							sx, sy = rect.x + math.floor(rect.w / 2), rect.y + math.floor(rect.h / 2)
						end
						if mode == "vertical" and iup.GetAttribute(rail, "TABTITLE" .. rect.pos) == "Merge target" then
							tx, ty = rect.x + math.floor(rect.w / 2), rect.y + rect.h - 2
						end
					end
					if mode == "sidebar" then tx = math.floor(E.state(iup.GetDialog(view)).w / 2) end
				end
				assert(sx and tx, "probe tabs missing")
				post(0x201, sx, sy)
			elseif step == 22 then post(0x200, tx, ty)
			elseif step == 25 then
				say("drag", order._drag and order._drag.moved, "feedback", feedback._state and feedback._state.kind)
				local comp = feedback._compositor
				say("compositor", comp and comp.last_error, comp and comp.backend.visible)
				say("backend", type(comp and comp.backend), comp and debug.getinfo(comp.backend.present).source)
				say("native", debug.getinfo(require("compositor").overlay).source)
				if comp then local g = comp:geometry(); say("geometry", g.w, g.h, g.unit, g.scale) end
				say("director error", feedback._director._last_error)
				if comp then local okc, errc = pcall(comp.commit, comp); say("commit", okc, errc) end
				if comp then for k in pairs(comp.groups) do say("group", k) end end
				assert(order._drag and order._drag.moved, "drag did not start")
				assert(feedback._state, "drop graphics missing")
				local expected = (mode == "sidebar" or mode == "reorder" or mode == "vertical" or mode == "off") and "caret" or "combine"
				assert(feedback._state.kind == expected, "wrong target cue")
				if mode == "off" then assert(not E.state(view).data.drag_source, "tab lifted with motion off") end
				R.backend().screenshot(outdir .. "/drag-" .. mode .. ".bmp")
			elseif step == 30 then post(0x202, tx, ty)
			elseif step == 35 then
				assert(not order._drag, "drag not cleared on release")
				local root = shell.groups():rootStrip()
				for i = 0, iup.GetChildCount(root) - 1 do say("after", i, iup.GetAttribute(root, "TABTITLE" .. i)) end
				if mode == "sidebar" then
					local found = false
					for _, rect in ipairs(require("core.imgui.widgets.flattabs").headerRects(view)) do
						if iup.GetAttribute(view, "TABTITLE" .. rect.pos) == "Drag source" then found = true end
					end
					assert(found, "sidebar drop did not reach the top toolbar")
				end
				out:close(); os.exit(0)
			end
		end)
		if not ok then say("ERROR", err); out:close(); os.exit(1) end
	end
	timer.run = "YES"
	return loop()
end
dofile(LUNAR_SOURCE_DIR .. "/src/lua/core/main.lua")
