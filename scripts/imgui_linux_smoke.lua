-- Full-shell Linux smoke probe. Run in a private X11/Wayland session:
-- lunar scripts/imgui_linux_smoke.lua /tmp/probe
-- Set LUNAR_PROFILE_DIR to the pack root and LUNAR_PROFILE='*'.
local iup = require("iup")
local R = require("core.imgui.Runtime")
local E = require("core.imgui.Element")
local Headers = require("core.imgui.widgets.flattabs")
require("core.classes.SettingsManager").save = function() return true end
require("core.ui.WelcomeTour").show = function() end
local outdir = assert(arg[1], "output directory required")
local out = assert(io.open(outdir .. "/linux-smoke.txt", "w"))
local function click(view, pos)
	for _, rect in ipairs(Headers.headerRects(view)) do
		if rect.pos == pos then
			local x, y = rect.x + rect.w / 2, rect.y + rect.h / 2
			R.deliver(view, { type = "press", button = 1, x = x, y = y })
			R.deliver(view, { type = "release", button = 1, x = x, y = y })
			return
		end
	end
	error("header missing: " .. pos)
end
local loop = iup.MainLoop
iup.MainLoop = function()
	local step, shell, groups, root, hpe, micro, expected, page, window = 0
	local timer = iup.timer{ time = 100 }
	function timer:action_cb()
		step = step + 1
		local ok, err = xpcall(function()
			if step == 10 then
				shell = assert(rawget(_G, "LUNAR_DEV_SHELL")); groups = shell.groups(); root = groups:rootStrip()
				for _, child in ipairs(groups:_children(root)) do
					local record = groups:groupOf(child)
					if record then
						if record.name:lower():find("hpe") then hpe = child end
						if record.name:lower():find("micro") then micro = child end
					end
				end
				assert(hpe and micro, "HPE and Microchip packs required")
				groups:setToolbar(hpe, "left"); groups:setToolbar(micro, "left")
				groups:setCollapsed(hpe, false); groups:setCollapsed(micro, false)
			elseif step >= 12 and step <= 24 then
				if expected then assert(iup.GetAttributeHandle(root, "VALUE_HANDLE") == expected, "group identity changed") end
				expected = step % 2 == 0 and hpe or micro
				click(shell.rail:widget(), groups:_posOf(expected))
			elseif step == 26 then
				groups:setCollapsed(hpe, true); assert(groups:isCollapsed(hpe))
				groups:setCollapsed(hpe, false); assert(not groups:isCollapsed(hpe))
				page = assert(groups:_children(hpe)[1]); window = assert(shell.tab_windows:open(page))
			elseif step == 29 then
				assert(iup.GetParent(page) == window.root)
				local id = assert(E.state(window.dialog).data.win)
				assert(R.backend().window("popup_ready", id))
				R.backend().screenshot(outdir .. "/linux-extension.bmp", 0, 0, 0, 0, id)
				R.redraw()
			elseif step == 32 then
				shell.tab_windows:restore(window); assert(iup.GetParent(page) == hpe)
				window = assert(shell.tab_windows:open(micro))
			elseif step == 35 then
				assert(iup.GetParent(micro) == window.root)
				R.backend().screenshot(outdir .. "/linux-group.bmp", 0, 0, 0, 0, assert(E.state(window.dialog).data.win))
				R.redraw()
			elseif step == 38 then
				shell.tab_windows:restore(window)
				assert(iup.GetParent(micro) == root and #shell.tab_windows.windows == 0)
				R.backend().screenshot(outdir .. "/linux-shell.bmp")
				R.redraw()
			elseif step == 40 then
				out:write("PASS: shell, group identity, collapse, extension and group pop-out/return\n")
				out:close(); os.exit(0)
			end
		end, debug.traceback)
		if not ok then out:write("FAIL: ", tostring(err), "\n"); out:close(); os.exit(1) end
	end
	timer.run = "YES"
	return loop()
end
dofile(LUNAR_SOURCE_DIR .. "/src/lua/core/main.lua")
