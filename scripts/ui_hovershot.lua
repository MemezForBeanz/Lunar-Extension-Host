-- scripts/ui_hovershot.lua -- buttons at rest and under the pointer, on either build.
--   Lunar <ABSOLUTE path>/scripts/ui_hovershot.lua <out_dir>       (off-screen)
-- Boots the app, then for each visible flat button, drop button and flat toggle on the
-- tool pages (up to 40) saves the control at rest and with the pointer over it (a real
-- WM_MOUSEMOVE), cropped from a PrintWindow of the main window, as
-- hover-<build>-<n>-<rest|hover>.bmp, and lists them in hover-<build>.txt (class, title,
-- page, rect, the colour attributes that decide the look). Nothing is clicked.
local ROOT
do
	local here = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
	ROOT = here:match("^(.*)/scripts/[^/]+$")
	if ROOT and ROOT ~= "" then
		local mine = ROOT .. "/src/lua/?.lua;" .. ROOT .. "/src/lua/?/init.lua"
		table.insert(package.loaders, 1, function(name)
			local file = package.searchpath(name, mine)
			if not file then return nil end
			return assert(loadfile(file))
		end)
	end
end
local ffi = require("ffi")
local iup = require("iup")
local IMGUI = rawget(iup, "_IMGUI") == true
local tag = IMGUI and "imgui" or "iup"
local out_dir = assert(arg and arg[1], "output directory required")
local out = assert(io.open(out_dir .. "/hover-" .. tag .. ".txt", "w"))
local function say(fmt, ...) out:write(string.format(fmt, ...), "\n"); out:flush() end

pcall(ffi.cdef, [[
typedef struct { long x, y; } HS_POINT;
typedef struct { long left, top, right, bottom; } HS_RECT;
typedef struct { uint32_t biSize; long biWidth, biHeight; uint16_t biPlanes, biBitCount;
  uint32_t biCompression, biSizeImage; long biXPelsPerMeter, biYPelsPerMeter; uint32_t biClrUsed, biClrImportant; } HS_BMIH;
]])
for _, d in ipairs({ "int ClientToScreen(void*, HS_POINT*);", "int GetClientRect(void*, HS_RECT*);",
	"int GetWindowRect(void*, HS_RECT*);", "void* GetDC(void*);", "int ReleaseDC(void*, void*);",
	"int PrintWindow(void*, void*, unsigned);", "void* CreateCompatibleDC(void*);",
	"void* CreateCompatibleBitmap(void*, int, int);", "void* SelectObject(void*, void*);",
	"int BitBlt(void*, int, int, int, int, void*, int, int, unsigned);",
	"int GetDIBits(void*, void*, unsigned, unsigned, void*, HS_BMIH*, unsigned);",
	"int DeleteObject(void*);", "int DeleteDC(void*);", "void* WindowFromPoint(HS_POINT);",
	"int ScreenToClient(void*, HS_POINT*);", "int PostMessageW(void*, unsigned, uintptr_t, intptr_t);" }) do
	pcall(ffi.cdef, d)
end
local user32, gdi32 = ffi.load("user32"), ffi.load("gdi32")

do
	local platform = require("core.platform")
	local os_backend = require(platform.is_windows and "core.platform.win32" or "core.platform.posix")
	for _, t in ipairs({ platform, os_backend }) do
		if t.open then t.open = function() return true end end
		if t.elevate then t.elevate = function() return true end end
	end
	iup.Message = function() end
	require("core.lib.async").probeTcp = function() return false, "probe" end
end

local host
local Manager = require("core.classes.ExtensionManager")
local load = Manager.loadAll
Manager.loadAll = function(self, ctx) host = ctx; return load(self, ctx) end

local function hwnd_of(d)
	if IMGUI then
		return ffi.cast("void*", ffi.cast("uintptr_t", tonumber(require("core.imgui.Runtime").backend().window("hwnd"))))
	end
	local IupFFI = require("core.classes.IupFFI")
	return ffi.cast("void*", IupFFI.getptr(IupFFI.ptr(d), "HWND"))
end

-- the main window's client as pixels
local function grab(h)
	local rc = ffi.new("HS_RECT"); user32.GetClientRect(h, rc)
	local w, hh = rc.right, rc.bottom
	local sdc = user32.GetDC(nil)
	local win = ffi.new("HS_RECT"); user32.GetWindowRect(h, win)
	local o = ffi.new("HS_POINT", 0, 0); user32.ClientToScreen(h, o)
	local ww, wh = win.right - win.left, win.bottom - win.top
	local wdc = gdi32.CreateCompatibleDC(sdc); local wb = gdi32.CreateCompatibleBitmap(sdc, ww, wh); local po = gdi32.SelectObject(wdc, wb)
	user32.PrintWindow(h, wdc, 2)
	local mem = gdi32.CreateCompatibleDC(sdc); local bmp = gdi32.CreateCompatibleBitmap(sdc, w, hh); local old = gdi32.SelectObject(mem, bmp)
	gdi32.BitBlt(mem, 0, 0, w, hh, wdc, o.x - win.left, o.y - win.top, 0x00CC0020)
	gdi32.SelectObject(wdc, po); gdi32.DeleteObject(wb); gdi32.DeleteDC(wdc)
	gdi32.SelectObject(mem, old)
	local bi = ffi.new("HS_BMIH"); bi.biSize, bi.biWidth, bi.biHeight, bi.biPlanes, bi.biBitCount = ffi.sizeof(bi), w, -hh, 1, 32
	local px = ffi.new("uint8_t[?]", w * hh * 4)
	gdi32.GetDIBits(mem, bmp, 0, hh, px, bi, 0)
	gdi32.DeleteObject(bmp); gdi32.DeleteDC(mem); user32.ReleaseDC(nil, sdc)
	return px, w, hh, o
end

local function save_crop(px, w, x, y, cw, ch, path)
	local function le(n, c) local t = {} for i = 1, c do t[i] = string.char(bit.band(bit.rshift(n, (i - 1) * 8), 255)) end return table.concat(t) end
	local rows = {}
	for row = 0, ch - 1 do rows[#rows + 1] = ffi.string(px + ((y + row) * w + x) * 4, cw * 4) end
	local bi = ffi.new("HS_BMIH"); bi.biSize, bi.biWidth, bi.biHeight, bi.biPlanes, bi.biBitCount = ffi.sizeof(bi), cw, -ch, 1, 32
	local f = assert(io.open(path, "wb"))
	f:write("BM", le(54 + cw * ch * 4, 4), le(0, 4), le(54, 4), ffi.string(bi, 40), table.concat(rows)); f:close()
end

local CLASSES = { flatbutton = true, dropbutton = true, flattoggle = true }
local function controls(root)
	local list = {}
	local function walk(h)
		if not h then return end
		local cls = iup.GetClassName(h)
		if CLASSES[cls] and iup.GetAttribute(h, "VISIBLE") ~= "NO" then
			local sx, sy = (iup.GetAttribute(h, "SCREENPOSITION") or ""):match("(-?%d+),(-?%d+)")
			local rw, rh = (iup.GetAttribute(h, "RASTERSIZE") or ""):match("(%d+)x(%d+)")
			if sx and rw and tonumber(rw) > 12 and tonumber(rh) > 12 then
				list[#list + 1] = { h = h, cls = cls, sx = tonumber(sx), sy = tonumber(sy), w = tonumber(rw), hgt = tonumber(rh) }
			end
		end
		local c = iup.GetChild(h, 0)
		while c do walk(c); c = iup.GetBrother(c) end
	end
	walk(root)
	return list
end

local queue, qi, phase, ticks = {}, 1, "boot", 0
local mainloop = iup.MainLoop
iup.MainLoop = function()
	local timer = iup.timer{ time = 60 }
	function timer:action_cb()
		local ok, err = xpcall(function()
			ticks = ticks + 1
			local h = hwnd_of(host.dialog)
			if phase == "boot" then
				if ticks < 40 then return end
				queue = controls(host.dialog)
				say("controls: %d", #queue)
				phase, ticks = "rest", 0
			elseif phase == "rest" then
				local q = queue[qi]
				if not q or qi > 40 then phase = "done"; return end
				local px, w, _, o = grab(h)
				q.x, q.y = q.sx - o.x, q.sy - o.y
				save_crop(px, w, math.max(0, q.x - 4), math.max(0, q.y - 4), q.w + 8, q.hgt + 8,
					string.format("%s/hover-%s-%02d-rest.bmp", out_dir, tag, qi))
				local pt = ffi.new("HS_POINT", q.sx + math.floor(q.w / 2), q.sy + math.floor(q.hgt / 2))
				local target = user32.WindowFromPoint(pt)
				local cp = ffi.new("HS_POINT", pt.x, pt.y); user32.ScreenToClient(target, cp)
				user32.PostMessageW(target, 0x0200, 0, bit.bor(bit.band(cp.x, 0xFFFF), bit.lshift(bit.band(cp.y, 0xFFFF), 16)))
				phase, ticks = "hover", 0
			elseif phase == "hover" then
				if ticks < 6 then return end -- 360 ms: any hover easing has finished
				local q = queue[qi]
				local px, w = grab(h)
				save_crop(px, w, math.max(0, q.x - 4), math.max(0, q.y - 4), q.w + 8, q.hgt + 8,
					string.format("%s/hover-%s-%02d-hover.bmp", out_dir, tag, qi))
				local function a(n) return tostring(iup.GetAttribute(q.h, n)) end
				say("%02d %s %q at %d,%d %dx%d BG=%s HL=%s PS=%s GRAD=%s FG=%s BORDER=%s RADIUS=%s SHEEN=%s", qi, q.cls,
					tostring(iup.GetAttribute(q.h, "TITLE")), q.x, q.y, q.w, q.hgt, a("BGCOLOR"), a("HLCOLOR"),
					a("PSCOLOR"), a("GRADIENTCOLOR"), a("FGCOLOR"), a("BORDERCOLOR"), a("CORNERRADIUS"), a("BORDERSHEENCOLOR"))
				-- move away so the next one starts at rest
				user32.PostMessageW(h, 0x0200, 0, bit.bor(5, bit.lshift(5, 16)))
				qi, phase, ticks = qi + 1, "rest", 0
			elseif phase == "done" then
				say("DONE")
				out:close()
				os.exit(0)
			end
		end, debug.traceback)
		if not ok then say("ERROR %s", tostring(err)); out:close(); os.exit(1) end
		return iup.DEFAULT
	end
	timer.run = "YES"
	return mainloop()
end

dofile((ROOT or LUNAR_SOURCE_DIR) .. "/src/lua/core/main.lua")
