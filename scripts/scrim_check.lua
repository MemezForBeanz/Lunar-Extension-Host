-- scripts/scrim_check.lua — the modal scrim on the real compositor, end to end.
--
-- Starts Lunar normally, opens a modal through core.ui.ModalMotion, and reads the
-- composed desktop (the backend's `screen_pixel`) at a point of the page the modal
-- doesn't cover:
--   * before the modal: the page's own colour
--   * at rest under the modal: dimmed by the scrim's alpha (Carbon: black at 50%)
--   * after the modal closes and the lift finishes: the page again, overlay hidden
-- and counts how the fade reached the screen (renders vs constant-alpha fades).
-- Runs on the Win32 and GTK backends; hosts without a compositor report SKIP.
--
-- Run (from build\win\bin): LunarExtensionHost.exe ..\..\..\scripts\scrim_check.lua
-- Run (Linux, repo root):   build/linux/bin/lunar scripts/scrim_check.lua

local iup = require("iup")
local ok_comp, compositor = pcall(require, "compositor")

local results = {}
local function report(name, pass, detail)
	results[#results + 1] = pass
	io.stdout:write(string.format("[%s] %s%s\n", pass and "PASS" or "FAIL", name,
		detail and (" -- " .. tostring(detail)) or ""))
	io.stdout:flush()
end
local function info(...) io.stdout:write("[info] ", table.concat({ ... }, " "), "\n"); io.stdout:flush() end

local function after(ms, fn)
	local t = iup.timer({ time = ms })
	function t.action_cb()
		t.run = "NO"
		local okf, err = pcall(fn)
		if not okf then report("step", false, err) iup.ExitLoop() end
		return iup.DEFAULT
	end
	t.run = "YES"
	return t
end

local function luma(r, g, b) return 0.2126 * r + 0.7152 * g + 0.0722 * b end

local real_mainloop = iup.MainLoop
iup.MainLoop = function()
	after(3000, function()
		if not ok_comp or not compositor.supported() then
			info("SKIP: no compositor backend on this platform")
			iup.ExitLoop()
			return
		end
		local ModalMotion = require("core.ui.ModalMotion")
		local scrim = ModalMotion.scrim()
		report("the host installed a scrim", scrim ~= nil)
		report("scrim prepared its compositor", scrim:prepare())
		local comp = scrim._compositor
		local ud = comp.backend
		-- Count what reaches the native layer.
		local counts = { present = 0, fade = 0 }
		comp.backend = setmetatable({
			present = function(_, ...) counts.present = counts.present + 1 return ud:present(...) end,
			fade = function(_, ...) counts.fade = counts.fade + 1 return ud:fade(...) end,
		}, { __index = function(_, k) return function(_, ...) return ud[k](ud, ...) end end })

		local cover = comp:rect(scrim._cover)
		local px, py = cover.x + 24, cover.y + cover.h - 24
		local r0, g0, b0 = ud:screen_pixel(px, py)
		local before = luma(r0, g0, b0)
		info(string.format("cover %dx%d at %d,%d; sample %d,%d = %d,%d,%d", cover.w, cover.h,
			cover.x, cover.y, px, py, r0, g0, b0))
		local director = scrim:director()
		info("motion enabled: " .. tostring(director and director:enabled()))

		local dlg = iup.dialog({ iup.vbox({ iup.label({ title = "Scrim check" }) ; margin = "40x40" }),
			title = "Scrim check", size = "200x80", parentdialog = iup.GetDialog(scrim._cover) })
		after(1600, function()
			local r1, g1, b1 = ud:screen_pixel(px, py)
			local dimmed = luma(r1, g1, b1)
			local want = before * (1 - 128 / 255)
			info(string.format("under the modal: %d,%d,%d (luma %.1f, want ~%.1f)", r1, g1, b1, dimmed, want))
			report("the page is dimmed by the scrim's alpha", math.abs(dimmed - want) <= 4,
				string.format("%.1f vs %.1f", dimmed, want))
			report("the overlay is visible", ud:visible())
			info(string.format("entrance: %d renders, %d constant-alpha fades", counts.present, counts.fade))
			report("the fade didn't re-render per frame", counts.present <= 2,
				counts.present .. " renders")
			ModalMotion.result(iup, dlg, "cancel")
			iup.Hide(dlg)
		end)
		ModalMotion.popup(iup, dlg)
		after(1200, function()
			local r2, g2, b2 = ud:screen_pixel(px, py)
			local back = luma(r2, g2, b2)
			report("the page comes back after the lift", math.abs(back - before) <= 3,
				string.format("%.1f vs %.1f", back, before))
			report("the overlay is hidden again", not ud:visible())
			report("the scrim's depth is back to 0", scrim:depth() == 0)
			pcall(iup.Destroy, dlg)
			local failed = 0
			for _, p in ipairs(results) do if not p then failed = failed + 1 end end
			io.stdout:write(failed == 0 and "ALL PASSED\n" or (failed .. " FAILED\n"))
			io.stdout:flush()
			iup.ExitLoop()
		end)
	end)
	return real_mainloop()
end

dofile((LUNAR_SOURCE_DIR or ".") .. "/src/lua/core/main.lua")
