-- scripts/ui_textmargin.lua -- where a native text field starts its text, on either build.
-- Lunar scripts/ui_textmargin.lua <out_dir>
-- Builds one dialog of iup.text / multiline fields (BORDER, PADDING, font, ALIGNMENT
-- variations), saves textmargin-<build>.bmp and textmargin-<build>.txt with each field's
-- client rectangle and the first and last column (and first row) holding glyph ink, so
-- the two builds can be compared without trusting either one's layout code.
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
local out = assert(io.open(out_dir .. "/textmargin-" .. tag .. ".txt", "w"))

ffi.cdef[[
typedef struct { long x, y; } TM_POINT;
typedef struct { long left, top, right, bottom; } TM_RECT;
typedef struct { uint32_t biSize; long biWidth, biHeight; uint16_t biPlanes, biBitCount;
  uint32_t biCompression, biSizeImage; long biXPelsPerMeter, biYPelsPerMeter; uint32_t biClrUsed, biClrImportant; } TM_BMIH;
int ClientToScreen(void*, TM_POINT*);
int GetClientRect(void*, TM_RECT*);
int GetWindowRect(void*, TM_RECT*);
void* GetDC(void*);
int ReleaseDC(void*, void*);
int PrintWindow(void*, void*, unsigned);
void* CreateCompatibleDC(void*);
void* CreateCompatibleBitmap(void*, int, int);
void* SelectObject(void*, void*);
int BitBlt(void*, int, int, int, int, void*, int, int, unsigned);
int GetDIBits(void*, void*, unsigned, unsigned, void*, TM_BMIH*, unsigned);
int DeleteObject(void*);
int DeleteDC(void*);
]]
local user32, gdi32 = ffi.load("user32"), ffi.load("gdi32")

local CASES = {
	{ "seg10 border pad0", { FONT = "Segoe UI, 10", BORDER = "YES", PADDING = "0x0" } },
	{ "seg10 border pad4", { FONT = "Segoe UI, 10", BORDER = "YES", PADDING = "4x2" } },
	{ "seg10 noborder pad0", { FONT = "Segoe UI, 10", BORDER = "NO", PADDING = "0x0" } },
	{ "seg10 noborder pad4", { FONT = "Segoe UI, 10", BORDER = "NO", PADDING = "4x2" } },
	{ "seg10 noborder nopad", { FONT = "Segoe UI, 10", BORDER = "NO" } },
	{ "seg10 border nopad", { FONT = "Segoe UI, 10", BORDER = "YES" } },
	{ "cons9 noborder pad0", { FONT = "Consolas, 9", BORDER = "NO", PADDING = "0x0" } },
	{ "seg12 noborder nopad", { FONT = "Segoe UI, 12", BORDER = "NO" } },
	{ "seg10 right noborder", { FONT = "Segoe UI, 10", BORDER = "NO", ALIGNMENT = "ARIGHT" } },
	{ "multi seg10 noborder", { FONT = "Segoe UI, 10", BORDER = "NO", MULTILINE = "YES", SCROLLBAR = "NO" } },
}

local fields, rows = {}, {}
for i, c in ipairs(CASES) do
	local t = iup.text{ VALUE = "Hlll", RASTERSIZE = "220x", BGCOLOR = "255 255 255", FGCOLOR = "0 0 0" }
	for k, v in pairs(c[2]) do iup.SetAttribute(t, k, v) end
	if c[2].MULTILINE then t.RASTERSIZE = "220x40" end
	fields[i] = t
	rows[#rows + 1] = t
end
rows.MARGIN, rows.GAP = "10x10", "10"
local dlg = iup.dialog{ iup.vbox(rows), TITLE = "text margins", RASTERSIZE = "400x600",
	BGCOLOR = "255 255 255", FONT = "Segoe UI, 10" }

local function hwnd_of()
	if IMGUI then return ffi.cast("void*", ffi.cast("uintptr_t", tonumber(require("core.imgui.Runtime").backend().window("hwnd")))) end
	local IupFFI = require("core.classes.IupFFI")
	return ffi.cast("void*", IupFFI.getptr(IupFFI.ptr(dlg), "HWND"))
end

local function grab()
	local hwnd = hwnd_of()
	local rc = ffi.new("TM_RECT"); user32.GetClientRect(hwnd, rc)
	local w, h = rc.right, rc.bottom
	local sdc = user32.GetDC(nil)
	local win = ffi.new("TM_RECT"); user32.GetWindowRect(hwnd, win)
	local o = ffi.new("TM_POINT", 0, 0); user32.ClientToScreen(hwnd, o)
	local ww, wh = win.right - win.left, win.bottom - win.top
	local wdc = gdi32.CreateCompatibleDC(sdc); local wb = gdi32.CreateCompatibleBitmap(sdc, ww, wh); local po = gdi32.SelectObject(wdc, wb)
	user32.PrintWindow(hwnd, wdc, 2)
	local mem = gdi32.CreateCompatibleDC(sdc); local bmp = gdi32.CreateCompatibleBitmap(sdc, w, h); local old = gdi32.SelectObject(mem, bmp)
	gdi32.BitBlt(mem, 0, 0, w, h, wdc, o.x - win.left, o.y - win.top, 0x00CC0020)
	gdi32.SelectObject(wdc, po); gdi32.DeleteObject(wb); gdi32.DeleteDC(wdc)
	gdi32.SelectObject(mem, old)
	local bi = ffi.new("TM_BMIH"); bi.biSize, bi.biWidth, bi.biHeight, bi.biPlanes, bi.biBitCount = ffi.sizeof(bi), w, -h, 1, 32
	local px = ffi.new("uint8_t[?]", w * h * 4)
	gdi32.GetDIBits(mem, bmp, 0, h, px, bi, 0)
	gdi32.DeleteObject(bmp); gdi32.DeleteDC(mem); user32.ReleaseDC(nil, sdc)
	return px, w, h
end

local function save(px, w, h, path)
	local f = assert(io.open(path, "wb"))
	local function le(n, c) local t = {} for i = 1, c do t[i] = string.char(bit.band(bit.rshift(n, (i - 1) * 8), 255)) end return table.concat(t) end
	local bi = ffi.new("TM_BMIH"); bi.biSize, bi.biWidth, bi.biHeight, bi.biPlanes, bi.biBitCount = ffi.sizeof(bi), w, -h, 1, 32
	f:write("BM", le(54 + w * h * 4, 4), le(0, 4), le(54, 4), ffi.string(bi, 40), ffi.string(px, w * h * 4)); f:close()
end

-- Ink is a pixel much darker than the white field (borders are light grey on both).
local function ink(px, w, x, y)
	local i = (y * w + x) * 4
	return px[i] + px[i + 1] + px[i + 2] < 3 * 140
end

local function report()
	local px, w, h = grab()
	save(px, w, h, string.format("%s/textmargin-%s.bmp", out_dir, tag))
	for i, c in ipairs(CASES) do
		local fx, fy = (iup.GetAttribute(fields[i], "POSITION") or "0,0"):match("(-?%d+),(-?%d+)")
		local fw, fh = (iup.GetAttribute(fields[i], "RASTERSIZE") or "0x0"):match("(%d+)x(%d+)")
		fx, fy, fw, fh = tonumber(fx), tonumber(fy), tonumber(fw), tonumber(fh)
		local first, last, top, bottom
		-- skip the outer 3 px of a bordered field so its border is never taken for ink
		local s = c[2].BORDER == "YES" and 3 or 0
		for y = fy + s, math.min(h - 1, fy + fh - 1 - s) do
			for x = fx + s, math.min(w - 1, fx + fw - 1 - s) do
				if ink(px, w, x, y) then
					first = math.min(first or x, x); last = math.max(last or x, x)
					top = math.min(top or y, y); bottom = math.max(bottom or y, y)
				end
			end
		end
		out:write(string.format("%-24s rect %d,%d %dx%d ink x %s..%s y %s..%s (rel %s, %s)\n", c[1], fx, fy, fw, fh,
			tostring(first), tostring(last), tostring(top), tostring(bottom),
			first and (first - fx) or "-", top and (top - fy) or "-"))
	end
	out:close()
end

dlg:showxy(0, 0)
local step = 0
local t = iup.timer{ time = 200 }
function t:action_cb()
	step = step + 1
	if step == 3 and IMGUI then
		local B = require("core.imgui.Runtime").backend(); B.window("pos", 0, 0)
	end
	if step == 6 then
		local ok, err = pcall(report)
		if not ok then out:write("ERR ", tostring(err), "\n"); out:close() end
		os.exit(0)
	end
	return iup.DEFAULT
end
t.run = "YES"
iup.MainLoop()
os.exit(0)
