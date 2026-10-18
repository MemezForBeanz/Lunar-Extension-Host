-- scripts/win32_overlay_probe.lua — Win32 compositor backend probe (Windows only).
--
-- The Windows counterpart of scripts/gtk_overlay_probe.lua, for the native
-- backend in src/c/libs/compositor/win32.c (a layered child window per dialog).
-- Checks, on a real IUP dialog with native and flat (canvas) controls:
--   * the overlay is created (layered child windows need Windows 8+ and the
--     manifest's compatibility entry)
--   * snapshots leave the overlay out
--   * a 50% scrim really blends: desktop pixels over a native button AND over a
--     flat button (a separate child window) drop to about half
--   * the overlay follows a resize and reports it; fade costs no re-render
--   * close, and destroying the dialog with an overlay still alive, are safe
-- With "interactive", a toast stays up for 40 s and real clicks are logged.
--
-- Run (from build\win\bin):
--   LunarExtensionHost.exe ..\..\..\scripts\win32_overlay_probe.lua [interactive]

local iup = require("iup")
local compositor = require("compositor")
local interactive = arg and arg[1] == "interactive"

-- Park the mouse in the screen's corner: a cursor left over the dialog can raise
-- a tooltip (a topmost popup, above any child overlay) right where a pixel is sampled.
pcall(function()
	local ffi = require("ffi")
	ffi.cdef("int SetCursorPos(int x, int y);")
	ffi.load("user32").SetCursorPos(0, 0)
end)

local results = {}
local function report(name, ok, detail)
	results[#results + 1] = { name = name, ok = ok }
	io.stdout:write(string.format("[%s] %s%s\n", ok and "PASS" or "FAIL", name,
		detail and (" -- " .. tostring(detail)) or ""))
	io.stdout:flush()
end
local function info(...) io.stdout:write("[info] ", table.concat({ ... }, " "), "\n"); io.stdout:flush() end

local native_btn = iup.button{ title = "Native button", rastersize = "160x30",
	action = function() io.stdout:write("CLICK native button (passed through the overlay)\n"); io.stdout:flush() end }
local flat_btn = iup.flatbutton{ title = "Flat button", CORNERRADIUS = "8", GRADIENTCOLOR = "0 120 255",
	BGCOLOR = "60 60 60", fgcolor = "255 255 255", rastersize = "160x34" }
local page = iup.vbox{
	iup.label{ title = "Native label" }, native_btn,
	iup.text{ value = "native entry", expand = "HORIZONTAL" }, flat_btn,
	iup.flatlabel{ title = "Flat label (canvas)", bgcolor = "200 200 200", rastersize = "200x24" },
	iup.list{ "one", "two", "three"; expand = "YES" },
	margin = "16x16", gap = "8",
}
local dlg = iup.dialog{ page, title = "Win32 overlay probe", rastersize = "520x360", bgcolor = "240 240 240" }
-- Top-left, away from the screen's bottom-right corner, where Windows puts its
-- notifications (topmost popups that would sit over the pixels this probe samples).
dlg:showxy(40, 40)
iup.Flush()

-- Centre of a widget in the dialog's client coordinates (POSITION is relative
-- to the native parent, which is the dialog for widgets in plain boxes).
local function centre(widget)
	local x, y = tostring(iup.GetAttribute(widget, "POSITION")):match("(%-?%d+),(%-?%d+)")
	local w, h = tostring(iup.GetAttribute(widget, "RASTERSIZE")):match("(%d+)x(%d+)")
	return math.floor(tonumber(x) + tonumber(w) / 2), math.floor(tonumber(y) + tonumber(h) / 2)
end

local function luminance(r, g, b) return (r or 0) * 0.299 + (g or 0) * 0.587 + (b or 0) * 0.114 end

local ok_sup, why_sup = compositor.supported()
info("compositor.supported:", tostring(ok_sup), tostring(why_sup or ""))
local ov, err = compositor.overlay(dlg)
report("layered child overlay created", ov ~= nil, err)
if not ov then
	io.stdout:write("1 FAILED\n")
	return
end

local function geometry() return ov:geometry() end
local function full_fill(color, alpha)
	local g = geometry()
	return { w = g.w, h = g.h, { kind = "fill", x = 0, y = 0, w = g.w, h = g.h, color = color, alpha = alpha } }
end

local steps = {}
local function step(fn) steps[#steps + 1] = fn end
local before = {}

-- 1. Baseline pixels with no overlay on screen, then prove captures exclude it.
step(function()
	local g = geometry()
	info(string.format("client %dx%d, scale %.2f", g.w, g.h, g.scale))
	for name, widget in pairs({ native = native_btn, flat = flat_btn }) do
		local x, y = centre(widget)
		before[name] = { x = x, y = y, lum = luminance(ov:screen_pixel(x, y)) }
	end
	assert(ov:present(full_fill(0xff00ff, 1), {}))
	local snap, serr = ov:snapshot()
	report("snapshot taken", snap ~= nil, serr)
	if snap then
		local b, g2, r = compositor.render({ w = 1, h = 1,
			{ kind = "image", snap = snap, x = -5, y = -5, alpha = 1 } }):pixel(0, 0)
		report("snapshot excludes the overlay (no magenta)", not (r == 255 and g2 == 0 and b == 255),
			string.format("pixel(5,5) = %d,%d,%d", r, g2, b))
		local part = ov:snapshot(native_btn)
		report("widget snapshot has the widget's size", part ~= nil and part.w == 160 and part.h == 30,
			part and (part.w .. "x" .. part.h) or "nil")
	end
end)

-- 2. A 50% scrim must really blend over both kinds of control.
step(function()
	local t0 = os.clock()
	assert(ov:present(full_fill(0x000000, 0.5), {}))
	info(string.format("scrim present (render + UpdateLayeredWindow): %.2f ms", (os.clock() - t0) * 1000))
	iup.Flush()
	for name, b in pairs(before) do
		local after = luminance(ov:screen_pixel(b.x, b.y))
		local expected = b.lum / 2
		report("50% scrim blends over the " .. name .. " button", math.abs(after - expected) <= 6,
			string.format("luminance %.0f -> %.0f (expected ~%.0f)", b.lum, after, expected))
	end
end)

-- 3. Scrim plus a toast whose close button is an action region.
step(function()
	local g = geometry()
	assert(ov:present({ w = g.w, h = g.h,
		{ kind = "fill", x = 0, y = 0, w = g.w, h = g.h, color = 0x000000, alpha = 0.3 },
		{ kind = "rrect", x = g.w - 230, y = g.h - 70, w = 210, h = 50, radius = 8, color = 0x262626, alpha = 0.97 },
		{ kind = "fill", x = g.w - 50, y = g.h - 58, w = 24, h = 24, color = 0xda1e28, alpha = 1 } },
		{ { x = g.w - 50, y = g.h - 58, w = 24, h = 24, mode = "action", id = "close:1" } }))
	report("toast frame presented", ov:visible())
end)

-- 4. Resize: applied on a later tick, then checked.
step(function()
	ov:events()   -- drop anything earlier
	iup.SetAttribute(dlg, "RASTERSIZE", "640x420")
	iup.Refresh(dlg)
end)
step(function()
	local got_resize = false
	for _, e in ipairs(ov:events()) do if e.type == "resize" then got_resize = true end end
	local g = geometry()
	report("resize event raised", got_resize)
	assert(ov:present(full_fill(0x000000, 0.5), {}))
	local corner = luminance(ov:screen_pixel(g.w - 3, g.h - 3))
	report("overlay covers the resized client area (corner dimmed)", corner < 160,
		string.format("client %dx%d, corner luminance %.0f", g.w, g.h, corner))
end)

-- 5. Fade cost: constant alpha versus re-rendering every frame.
step(function()
	local t0 = os.clock()
	for i = 1, 60 do ov:fade(i / 60) end
	local fade_ms = (os.clock() - t0) * 1000 / 60
	t0 = os.clock()
	for i = 1, 60 do ov:present(full_fill(0x000000, i / 120), {}) end
	local render_ms = (os.clock() - t0) * 1000 / 60
	local g = geometry()
	info(string.format("at %dx%d: fade %.2f ms/frame, re-render %.2f ms/frame (CPU)", g.w, g.h, fade_ms, render_ms))
end)

-- 5b. Interactive: real clicks for 40 s.
if interactive then
	step(function()
		local g = geometry()
		assert(ov:present({ w = g.w, h = g.h,
			{ kind = "rrect", x = g.w - 230, y = g.h - 70, w = 210, h = 50, radius = 8, color = 0x262626, alpha = 0.97 },
			{ kind = "fill", x = g.w - 50, y = g.h - 58, w = 24, h = 24, color = 0xda1e28, alpha = 1 } },
			{ { x = g.w - 50, y = g.h - 58, w = 24, h = 24, mode = "action", id = "close:1" } }))
		io.stdout:write("INTERACTIVE: click 'Native button', type in the entry, then click the red square (40 s)\n")
		io.stdout:flush()
	end)
	for _ = 1, 26 do
		step(function()
			for _, e in ipairs(ov:events()) do
				if e.type == "action" then
					io.stdout:write("CLICK toast close button (overlay action region, id " .. tostring(e.id) .. ")\n")
					io.stdout:flush()
				end
			end
		end)
	end
end

-- 6. Teardown: close, then destroy a dialog whose overlay is still alive.
step(function()
	ov:close()
	ov:close()
	-- A fixed scene: a closed overlay has no geometry to size one from.
	local ok = ov:present({ w = 10, h = 10, { kind = "fill", x = 0, y = 0, w = 10, h = 10, color = 0, alpha = 1 } }, {})
	report("close is idempotent and a closed overlay refuses to present", ok == false)
	local d2 = iup.dialog{ iup.label{ title = "second" }, rastersize = "200x100" }
	d2:showxy(iup.LEFT, iup.TOP)
	local ov2 = assert(compositor.overlay(d2))
	assert(ov2:present({ w = 10, h = 10, { kind = "fill", x = 0, y = 0, w = 10, h = 10, color = 0, alpha = 1 } }, {}))
	iup.Destroy(d2)
	report("destroying the dialog closes its overlay", ov2:visible() == false and ov2:geometry() == nil)
end)

local i = 0
local timer = iup.timer{ time = 1500 }
function timer:action_cb()
	i = i + 1
	if steps[i] then
		local ok, e = pcall(steps[i])
		if not ok then report("step " .. i, false, e) end
		return iup.DEFAULT
	end
	self.run = "NO"
	local failed = 0
	for _, r in ipairs(results) do if not r.ok then failed = failed + 1 end end
	io.stdout:write(failed == 0 and "ALL PASSED\n" or (failed .. " FAILED\n")); io.stdout:flush()
	return iup.CLOSE
end
timer.run = "YES"
iup.MainLoop()
