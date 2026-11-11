-- scripts/ui_dialogwin.lua -- a secondary dialog on either build, as Windows sees it.
-- Lunar scripts/ui_dialogwin.lua <out_dir>
-- Shows a main dialog and a secondary one (TITLE, PARENTDIALOG, MINBOX=NO, MAXBOX=NO, a
-- label and a button), then reports what the secondary dialog's native window is: its
-- styles, owner, title, where its client sits against the main window's client, and its
-- pixels (PrintWindow, saved as dialogwin-<build>.bmp). Then it clicks the button and uses
-- the close button through window messages, and reports what the callbacks saw.
local iup = require("iup")
local ffi = require("ffi")
do
	local here = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
	local root = here:match("^(.*)/scripts/[^/]+$")
	if root and root ~= "" then
		local mine = root .. "/src/lua/?.lua;" .. root .. "/src/lua/?/init.lua"
		table.insert(package.loaders, 2, function(name)
			local file = package.searchpath(name, mine)
			if not file then return nil end
			return assert(loadfile(file))
		end)
	end
end
local IMGUI = rawget(iup, "_IMGUI") == true
local out_dir = (arg and arg[1]) or "."
local tag = IMGUI and "imgui" or "iup"
local out = assert(io.open(out_dir .. "/dialogwin-" .. tag .. ".txt", "w"))

pcall(ffi.cdef, [[
typedef struct { long x, y; } DW_POINT;
typedef struct { long left, top, right, bottom; } DW_RECT;
typedef struct { uint32_t biSize; long biWidth, biHeight; uint16_t biPlanes, biBitCount;
  uint32_t biCompression, biSizeImage; long biXPelsPerMeter, biYPelsPerMeter; uint32_t biClrUsed, biClrImportant; } DW_BMIH;
]])
local function decl(s) pcall(ffi.cdef, s) end
decl("int ClientToScreen(void*, DW_POINT*);")
decl("int ScreenToClient(void*, DW_POINT*);")
decl("int GetClientRect(void*, DW_RECT*);")
decl("int GetWindowRect(void*, DW_RECT*);")
decl("long GetWindowLongW(void*, int);")
decl("void* GetWindow(void*, unsigned);")
decl("int GetWindowTextW(void*, uint16_t*, int);")
decl("int IsWindowVisible(void*);")
decl("int IsWindowEnabled(void*);")
decl("void* WindowFromPoint(DW_POINT);")
decl("int PostMessageW(void*, unsigned, uintptr_t, intptr_t);")
decl("void* GetDC(void*);")
decl("int ReleaseDC(void*, void*);")
decl("int PrintWindow(void*, void*, unsigned);")
decl("void* CreateCompatibleDC(void*);")
decl("void* CreateCompatibleBitmap(void*, int, int);")
decl("void* SelectObject(void*, void*);")
decl("int BitBlt(void*, int, int, int, int, void*, int, int, unsigned);")
decl("int GetDIBits(void*, void*, unsigned, unsigned, void*, DW_BMIH*, unsigned);")
decl("int DeleteObject(void*);")
decl("int DeleteDC(void*);")
local user32, gdi32 = ffi.load("user32"), ffi.load("gdi32")

local clicks, closes = 0, 0
local main = iup.dialog{ iup.vbox{ iup.label{ TITLE = "Main window" }, MARGIN = "10x10" },
	TITLE = "Probe main", RASTERSIZE = "640x480" }
local btn = iup.button{ TITLE = "Go", RASTERSIZE = "80x28" }
function btn:action() clicks = clicks + 1; return iup.DEFAULT end
local dlg = iup.dialog{ iup.vbox{ iup.label{ TITLE = "inside the dialog" }, btn, MARGIN = "10x10", GAP = "8" },
	TITLE = "Second", RASTERSIZE = "320x200", MINBOX = "NO", MAXBOX = "NO", PARENTDIALOG = main,
	BGCOLOR = "240 240 240", FONT = "Segoe UI, 9" }
function dlg:close_cb() closes = closes + 1; return iup.DEFAULT end

local function hwnd(d)
	if IMGUI then
		local v = tonumber(iup.GetAttribute(d, "HWND")) or 0
		return ffi.cast("void*", ffi.cast("uintptr_t", v))
	end
	local IupFFI = require("core.classes.IupFFI")
	return ffi.cast("void*", IupFFI.getptr(IupFFI.ptr(d), "HWND"))
end
local function addr(p) return tonumber(ffi.cast("uintptr_t", p)) end

local function grab(h)
	local rc = ffi.new("DW_RECT"); user32.GetClientRect(h, rc)
	local w, hh = rc.right, rc.bottom
	local sdc = user32.GetDC(nil)
	local win = ffi.new("DW_RECT"); user32.GetWindowRect(h, win)
	local o = ffi.new("DW_POINT", 0, 0); user32.ClientToScreen(h, o)
	local ww, wh = win.right - win.left, win.bottom - win.top
	local wdc = gdi32.CreateCompatibleDC(sdc); local wb = gdi32.CreateCompatibleBitmap(sdc, ww, wh); local po = gdi32.SelectObject(wdc, wb)
	user32.PrintWindow(h, wdc, 2)
	local bi = ffi.new("DW_BMIH"); bi.biSize, bi.biWidth, bi.biHeight, bi.biPlanes, bi.biBitCount = ffi.sizeof(bi), ww, -wh, 1, 32
	local px = ffi.new("uint8_t[?]", ww * wh * 4)
	gdi32.SelectObject(wdc, po)
	gdi32.GetDIBits(wdc, wb, 0, wh, px, bi, 0)
	gdi32.DeleteObject(wb); gdi32.DeleteDC(wdc); user32.ReleaseDC(nil, sdc)
	return px, ww, wh, o.x - win.left, o.y - win.top, w, hh
end

local function save(px, w, h, path)
	local f = assert(io.open(path, "wb"))
	local function le(n, c) local t = {} for i = 1, c do t[i] = string.char(bit.band(bit.rshift(n, (i - 1) * 8), 255)) end return table.concat(t) end
	local bi = ffi.new("DW_BMIH"); bi.biSize, bi.biWidth, bi.biHeight, bi.biPlanes, bi.biBitCount = ffi.sizeof(bi), w, -h, 1, 32
	f:write("BM", le(54 + w * h * 4, 4), le(0, 4), le(54, 4), ffi.string(bi, 40), ffi.string(px, w * h * 4)); f:close()
end

local function report_window()
	local h, m = hwnd(dlg), hwnd(main)
	local style = bit.band(user32.GetWindowLongW(h, -16), 0xFFFFFFFF)
	local ex = bit.band(user32.GetWindowLongW(h, -20), 0xFFFFFFFF)
	local buf = ffi.new("uint16_t[256]"); local n = user32.GetWindowTextW(h, buf, 256)
	local title = {}; for i = 0, n - 1 do title[#title + 1] = string.char(math.min(buf[i], 126)) end
	local mo = ffi.new("DW_POINT", 0, 0); user32.ClientToScreen(m, mo)
	local px, ww, wh, cx, cy, cw, ch = grab(h)
	save(px, ww, wh, string.format("%s/dialogwin-%s.bmp", out_dir, tag))
	local o = ffi.new("DW_POINT", 0, 0); user32.ClientToScreen(h, o)
	out:write(string.format("separate window %s\n", tostring(addr(h) ~= addr(m) and addr(h) ~= 0)))
	-- WS_VISIBLE and WS_CLIPCHILDREN depend on the host (child controls), not on IUP's choice
	out:write(string.format("style 0x%08x (masked 0x%08x) exstyle 0x%08x\n", style, bit.band(style, bit.bnot(0x12000000)), ex))
	out:write(string.format("owner is main %s\n", tostring(addr(user32.GetWindow(h, 4)) == addr(m))))
	out:write(string.format("title %q visible %d\n", table.concat(title), user32.IsWindowVisible(h)))
	out:write(string.format("window %dx%d client %dx%d client at %d,%d in the window\n", ww, wh, cw, ch, cx, cy))
	out:write(string.format("client origin against main client %d,%d\n", o.x - mo.x, o.y - mo.y))
	-- ink in the client: dark pixels (the label and button text)
	local dark, bg = 0, nil
	for y = cy, cy + ch - 1 do for x = cx, cx + cw - 1 do
		local i = (y * ww + x) * 4
		if px[i] + px[i + 1] + px[i + 2] < 3 * 100 then dark = dark + 1 end
	end end
	local i = ((cy + ch - 5) * ww + cx + cw - 5) * 4
	bg = string.format("%d %d %d", px[i + 2], px[i + 1], px[i])
	out:write(string.format("client background %s dark pixels %d\n", bg, dark))
	out:write(string.format("main enabled %d\n", user32.IsWindowEnabled(m)))
end

local function click_button()
	local h = hwnd(dlg)
	local bx, by = (iup.GetAttribute(btn, "POSITION") or "0,0"):match("(-?%d+),(-?%d+)")
	local o = ffi.new("DW_POINT", 0, 0); user32.ClientToScreen(h, o)
	local sp = ffi.new("DW_POINT", o.x + tonumber(bx) + 20, o.y + tonumber(by) + 10)
	local target = user32.WindowFromPoint(sp)
	local cp = ffi.new("DW_POINT", sp.x, sp.y); user32.ScreenToClient(target, cp)
	local l = bit.bor(bit.band(cp.x, 0xFFFF), bit.lshift(bit.band(cp.y, 0xFFFF), 16))
	out:write(string.format("click target is %s\n", addr(target) == addr(h) and "the dialog window" or "a child window"))
	user32.PostMessageW(target, 0x0200, 0, l)      -- WM_MOUSEMOVE
	user32.PostMessageW(target, 0x0201, 1, l)      -- WM_LBUTTONDOWN
	user32.PostMessageW(target, 0x0202, 0, l)      -- WM_LBUTTONUP
end

iup.ShowXY(main, 100, 100)
iup.Show(dlg)
local step = 0
local t = iup.timer{ time = 200 }
function t:action_cb()
	step = step + 1
	local ok, err = true, nil
	if step == 4 then ok, err = pcall(report_window)
	elseif step == 5 then ok, err = pcall(click_button)
	elseif step == 7 then
		out:write(string.format("button clicks %d\n", clicks))
		user32.PostMessageW(hwnd(dlg), 0x0010, 0, 0) -- WM_CLOSE: the close button
	elseif step == 9 then
		out:write(string.format("close_cb %d dialog VISIBLE %s window visible %d\n", closes,
			tostring(iup.GetAttribute(dlg, "VISIBLE")), user32.IsWindowVisible(hwnd(dlg))))
		out:write(string.format("main enabled after %d\n", user32.IsWindowEnabled(hwnd(main))))
		out:close()
		os.exit(0)
	end
	if not ok then out:write("ERR ", tostring(err), "\n") end
	return iup.DEFAULT
end
t.run = "YES"
iup.MainLoop()
os.exit(0)
