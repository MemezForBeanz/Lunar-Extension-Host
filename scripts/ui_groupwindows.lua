-- Native org-pack regression: toolbar identity, double-click collapse, window
-- limits, and live extension/group pop-out/return. Run on a private desktop.
local iup = require("iup")
local R = require("core.imgui.Runtime")
local E = require("core.imgui.Element")
local Headers = require("core.imgui.widgets.flattabs")
local ffi = require("ffi")
require("core.classes.SettingsManager").save = function() return true end
local outdir = assert(arg[1], "output directory required")
local out = assert(io.open(outdir .. "/group-windows.txt", "w"))
local function say(...)
	local a = {}; for n = 1, select("#", ...) do a[n] = tostring(select(n, ...)) end
	out:write(table.concat(a, " "), "\n"); out:flush()
end
ffi.cdef[[
typedef struct { long x, y; } GW_POINT;
typedef struct { GW_POINT reserved, max_size, max_pos, min_track, max_track; } GW_MINMAX;
intptr_t SendMessageW(void*, unsigned, uintptr_t, intptr_t);
int PostMessageA(void*, unsigned, uintptr_t, intptr_t);
]]
local user = ffi.load("user32")
local order
local Order = require("core.classes.TabOrder")
local set_windows = Order.setWindows
Order.setWindows = function(self, windows) order = self; return set_windows(self, windows) end
local function hwnd(id)
	return ffi.cast("void*", tonumber(R.backend().window(id and "popup_hwnd" or "hwnd", id)))
end
local function click(view, pos, double)
	for _, rect in ipairs(Headers.headerRects(view)) do
		if rect.pos == pos then
			local x, y = math.floor(rect.x + rect.w / 2), math.floor(rect.y + rect.h / 2)
			local lp = y * 65536 + x
			user.PostMessageA(hwnd(), double and 0x203 or 0x201, 1, lp)
			user.PostMessageA(hwnd(), 0x202, 0, lp)
			return
		end
	end
	error("toolbar header missing: " .. pos)
end
local loop = iup.MainLoop
iup.MainLoop = function()
	local step, shell, groups, root, hpe, micro, rail, expected, page, window = 0
	local timer = iup.timer{ time = 100 }
	function timer:action_cb()
		step = step + 1
		local ok, err = pcall(function()
			if step == 20 then
				shell = assert(rawget(_G, "LUNAR_DEV_SHELL")); groups = shell.groups(); root = groups:rootStrip()
				for _, child in ipairs(groups:_children(root)) do
					local record = groups:groupOf(child)
					if record then
						say("group", record.name, #groups:_children(child))
						if record.name:lower():find("hpe") then hpe = child end
						if record.name:lower():find("micro") then micro = child end
					end
				end
				assert(hpe and micro, "load the HPE and Microchip packs for this probe")
				groups:setToolbar(hpe, "left"); groups:setToolbar(micro, "left")
				groups:setCollapsed(hpe, false); groups:setCollapsed(micro, false)
				if not shell.view_layout:barsVisible() then shell.view_layout:toggleBars() end
				rail = shell.rail:widget()
			elseif step >= 25 and step <= 42 then
				if expected then
					assert(iup.GetAttributeHandle(root, "VALUE_HANDLE") == expected, "group selection is one click behind")
					assert(tonumber(iup.GetAttribute(rail, "VALUEPOS")) == groups:_posOf(expected), "group icon does not match its content")
				end
				expected = step % 2 == 0 and hpe or micro
				click(rail, groups:_posOf(expected))
			elseif step == 44 then
				click(rail, groups:_posOf(hpe), true)
			elseif step == 46 then
				assert(groups:isCollapsed(hpe), "double-click did not collapse group")
				say("double-click", "collapsed")
				click(rail, groups:_posOf(hpe), true)
			elseif step == 48 then
				assert(not groups:isCollapsed(hpe), "double-click did not restore group")
				say("switching", "18 clicks aligned", "collapse and restore passed")
				local mm = ffi.new("GW_MINMAX[1]")
				user.SendMessageW(hwnd(), 0x24, 0, ffi.cast("intptr_t", mm))
				assert(mm[0].min_track.x >= 700 and mm[0].min_track.y >= 500, "native minimum missing")
				say("minimum", mm[0].min_track.x, mm[0].min_track.y)
				page = assert(groups:_children(hpe)[1])
				window = shell.tab_windows:open(page)
			elseif step == 51 then
				assert(iup.GetParent(page) == window.root, "extension did not pop out")
				local id = assert(E.state(window.dialog).data.win)
				local mm = ffi.new("GW_MINMAX[1]")
				user.SendMessageW(hwnd(id), 0x24, 0, ffi.cast("intptr_t", mm))
				assert(mm[0].min_track.x >= 500 and mm[0].min_track.y >= 360)
				R.backend().screenshot(outdir .. "/extension-window.bmp", 0, 0, 0, 0, id)
				say("extension", "native window", id, "minimum", mm[0].min_track.x, mm[0].min_track.y)
			elseif step == 54 then
				user.PostMessageA(hwnd(E.state(window.dialog).data.win), 0x10, 0, 0)
			elseif step == 57 then
				assert(iup.GetParent(page) == hpe, "native close lost the extension")
				say("extension", "returned to HPE")
				window = shell.tab_windows:open(micro)
			elseif step == 60 then
				assert(iup.GetParent(micro) == window.root)
				local id = assert(E.state(window.dialog).data.win)
				R.backend().screenshot(outdir .. "/group-window.bmp", 0, 0, 0, 0, id)
				say("group", "native window", id, #groups:_children(micro), "extensions preserved")
			elseif step == 63 then
				user.PostMessageA(hwnd(E.state(window.dialog).data.win), 0x10, 0, 0)
			elseif step == 66 then
				assert(iup.GetParent(micro) == root)
				assert(#shell.tab_windows.windows == 0)
				say("group", "returned to main", "PASS")
				groups:setToolbar(hpe, "top")
				groups:setIconOnly(hpe, true)
				local theme = os.getenv("LUNAR_PROBE_THEME")
				if theme then require("core.ui.ThemeReactor").themeManager():apply(theme, { skip_save = true, force = true }) end
				assert(iup.GetAttributeId(root, "TABTITLE", groups:_posOf(hpe)) == "")
				say("icon only", "full group name retained", groups:groupOf(hpe).name)
			elseif step == 68 then
				order:_showMenu(root, groups:_posOf(hpe))
				-- Reopen at a deterministic screen point rather than the OS cursor.
				for _, overlay in ipairs({ unpack(R.overlays()) }) do overlay:close() end
				order._menu:popup(400, 100)
				local overlay = R.overlays()[#R.overlays()]
				overlay.event{ type = "move", x = overlay.x + 20, y = overlay.y + 10 }
				local theme = require("core.ui.ThemeReactor").themeManager():activeTheme()
				local rule = theme:rules().dropdown_list
				say("menu theme", theme:id(), "surface", rule.bg, "selection", rule.selbg, "text", rule.fg)
				say("menu rect", overlay.x, overlay.y, overlay.w, overlay.h)
			elseif step == 70 then
				R.backend().screenshot(outdir .. "/group-menu.bmp")
			elseif step == 73 then
				groups:setIconOnly(hpe, false)
				assert(iup.GetAttributeId(root, "TABTITLE", groups:_posOf(hpe)) == groups:groupOf(hpe).name)
				say("menu and icon toggle", "PASS")
				out:close(); os.exit(0)
			end
		end)
		if not ok then say("ERROR", err); out:close(); os.exit(1) end
	end
	timer.run = "YES"
	return loop()
end
dofile(LUNAR_SOURCE_DIR .. "/src/lua/core/main.lua")
