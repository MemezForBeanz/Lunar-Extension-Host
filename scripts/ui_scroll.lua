-- scripts/ui_scroll.lua -- native scroll bars (IupScrollBox, multiline, list) on either build,
-- driven through real window messages. Lunar scripts/ui_scroll.lua <out_dir>
-- Writes scroll-<build>.txt (geometry, positions after each input) and scroll-<build>-N.bmp.
-- It does not load the shell: one dialog, two scroll boxes, a multiline and a list.
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
local out = assert(io.open(out_dir .. "/scroll-" .. tag .. ".txt", "w"))
local function say(...) local t = {} for i = 1, select("#", ...) do t[i] = tostring((select(i, ...))) end out:write(table.concat(t, " "), "\n"); out:flush() end

ffi.cdef[[
typedef struct { long x, y; } SC_POINT;
typedef struct { long left, top, right, bottom; } SC_RECT;
typedef struct { uint32_t cbSize; SC_RECT rcScrollBar; int dxyLineButton, xyThumbTop, xyThumbBottom, reserved; uint32_t rgstate[6]; } SC_SBI;
typedef struct { uint32_t biSize; long biWidth, biHeight; uint16_t biPlanes, biBitCount;
  uint32_t biCompression, biSizeImage; long biXPelsPerMeter, biYPelsPerMeter; uint32_t biClrUsed, biClrImportant; } SC_BMIH;
int ClientToScreen(void*, SC_POINT*);
int ScreenToClient(void*, SC_POINT*);
void* ChildWindowFromPointEx(void*, SC_POINT, unsigned);
int PostMessageA(void*, unsigned, uintptr_t, intptr_t);
intptr_t SendMessageA(void*, unsigned, uintptr_t, intptr_t);
int GetScrollBarInfo(void*, long, SC_SBI*);
int GetClientRect(void*, SC_RECT*);
int GetWindowRect(void*, SC_RECT*);
int MoveWindow(void*, int, int, int, int, int);
void* GetDC(void*);
int ReleaseDC(void*, void*);
int PrintWindow(void*, void*, unsigned);
void* CreateCompatibleDC(void*);
void* CreateCompatibleBitmap(void*, int, int);
void* SelectObject(void*, void*);
int BitBlt(void*, int, int, int, int, void*, int, int, unsigned);
int GetDIBits(void*, void*, unsigned, unsigned, void*, SC_BMIH*, unsigned);
int DeleteObject(void*);
int DeleteDC(void*);
int SetCursorPos(int, int);
uint32_t GetLastError(void);
]]
local user32, gdi32 = ffi.load("user32"), ffi.load("gdi32")

local rect, target
local dlg, main_hwnd
local function hwnd_of(h)
	if IMGUI then return ffi.cast("void*", ffi.cast("uintptr_t", tonumber(require("core.imgui.Runtime").backend().window("hwnd")))) end
	local IupFFI = require("core.classes.IupFFI")
	local hw = ffi.cast("void*", IupFFI.getptr(IupFFI.ptr(h), "HWND"))
	if hw == nil and main_hwnd then -- a native control IupFFI cannot read: the window at its centre
		local x, y, w, hh = rect(h)
		hw = target(x + math.floor(w / 2), y + math.floor(hh / 2))
	end
	return hw
end
local function lp(x, y) return bit.bor(bit.band(x, 0xFFFF), bit.lshift(bit.band(y, 0xFFFF), 16)) end

-- client rect of an element in main-window client coordinates
function rect(h)
	local o = ffi.new("SC_POINT", 0, 0); user32.ClientToScreen(main_hwnd, o)
	local sp = iup.GetAttribute(h, "SCREENPOSITION")
	if not sp then -- a void box: its first child's place less its own POSITION offset
		local first = iup.GetChild(h, 0)
		local fx, fy = rect(first)
		local px, py = tostring(iup.GetAttribute(first, "POSITION")):match("^(-?%d+),(-?%d+)")
		local qx, qy = tostring(iup.GetAttribute(h, "POSITION")):match("^(-?%d+),(-?%d+)")
		local w, hh = tostring(iup.GetAttribute(h, "RASTERSIZE")):match("^(%d+)x(%d+)")
		return fx - (tonumber(px) - tonumber(qx)), fy - (tonumber(py) - tonumber(qy)), tonumber(w), tonumber(hh)
	end
	local x, y = tostring(sp):match("^(-?%d+),(-?%d+)")
	local w, hh = tostring(iup.GetAttribute(h, "RASTERSIZE")):match("^(%d+)x(%d+)")
	return tonumber(x) - o.x, tonumber(y) - o.y, tonumber(w), tonumber(hh)
end
-- the deepest window at main-client (x, y), and the point in its client coordinates
function target(x, y)
	local t, pt = main_hwnd, ffi.new("SC_POINT", x, y)
	if not IMGUI then
		while true do
			local c = user32.ChildWindowFromPointEx(t, pt, 5)
			if c == nil or c == t then break end
			local s = ffi.new("SC_POINT", pt.x, pt.y); user32.ClientToScreen(t, s); user32.ScreenToClient(c, s)
			t, pt = c, s
		end
	end
	return t, pt.x, pt.y
end
local function screen(x, y) local p = ffi.new("SC_POINT", x, y); user32.ClientToScreen(main_hwnd, p); return p.x, p.y end
local WM = { move = 0x0200, down = 0x0201, up = 0x0202, wheel = 0x020A, ncmove = 0x00A0, ncdown = 0x00A1, ncup = 0x00A2 }
-- a mouse message at main-client (x, y). On IUP a point on a native scroll bar is in the
-- non-client area of the scroll box's window: NC messages with HTVSCROLL/HTHSCROLL.
local function mouse(kind, x, y, ht, hwnd_nc, held)
	local sx, sy = screen(x, y)
	if not IMGUI and ht then
		local m = ({ move = WM.ncmove, down = WM.ncdown, up = WM.ncup })[kind]
		if kind == "up" then
			-- the tracking loop ends on a client WM_LBUTTONUP (it holds the capture)
			local p = ffi.new("SC_POINT", sx, sy); user32.ScreenToClient(hwnd_nc, p)
			user32.PostMessageA(hwnd_nc, WM.up, 0, lp(p.x, p.y))
		else
			user32.PostMessageA(hwnd_nc, m, ht, lp(sx, sy))
		end
		return
	end
	if kind == "wheel" then
		local t = target(x, y)
		user32.PostMessageA(IMGUI and main_hwnd or t, WM.wheel, bit.lshift(bit.band(-120, 0xFFFF), 16), lp(sx, sy))
		return
	end
	local t, px, py = target(x, y)
	user32.PostMessageA(t, WM[kind], kind == "down" and 1 or (kind == "move" and held and 1 or 0), lp(px, py))
end

local function save_bmp(path)
	if IMGUI then
		local Runtime = require("core.imgui.Runtime")
		Runtime.backend().screenshot(path); Runtime.frame(); return
	end
	local rc = ffi.new("SC_RECT"); user32.GetClientRect(main_hwnd, rc)
	local w, h = rc.right, rc.bottom
	local sdc = user32.GetDC(nil)
	local win = ffi.new("SC_RECT"); user32.GetWindowRect(main_hwnd, win)
	local o = ffi.new("SC_POINT", 0, 0); user32.ClientToScreen(main_hwnd, o)
	local ww, wh = win.right - win.left, win.bottom - win.top
	local wdc = gdi32.CreateCompatibleDC(sdc); local wb = gdi32.CreateCompatibleBitmap(sdc, ww, wh); local po = gdi32.SelectObject(wdc, wb)
	user32.PrintWindow(main_hwnd, wdc, 2)
	local mem = gdi32.CreateCompatibleDC(sdc); local bmp = gdi32.CreateCompatibleBitmap(sdc, w, h); local old = gdi32.SelectObject(mem, bmp)
	gdi32.BitBlt(mem, 0, 0, w, h, wdc, o.x - win.left, o.y - win.top, 0x00CC0020)
	gdi32.SelectObject(wdc, po); gdi32.DeleteObject(wb); gdi32.DeleteDC(wdc)
	gdi32.SelectObject(mem, old)
	local bi = ffi.new("SC_BMIH"); bi.biSize, bi.biWidth, bi.biHeight, bi.biPlanes, bi.biBitCount = ffi.sizeof(bi), w, h, 1, 32
	local px = ffi.new("uint8_t[?]", w * h * 4)
	gdi32.GetDIBits(mem, bmp, 0, h, px, bi, 0)
	gdi32.DeleteObject(bmp); gdi32.DeleteDC(mem); user32.ReleaseDC(nil, sdc)
	local f = assert(io.open(path, "wb"))
	local function le(n, c) local t = {} for i = 1, c do t[i] = string.char(bit.band(bit.rshift(n, (i - 1) * 8), 255)) end return table.concat(t) end
	f:write("BM", le(54 + w * h * 4, 4), le(0, 4), le(54, 4), ffi.string(bi, 40), ffi.string(px, w * h * 4)); f:close()
end

-- What each build says about a native scroll bar: IUP asks Windows (GetScrollBarInfo,
-- in the box's window), the host asks its port (core.imgui.widgets.winscrollbar.info).
local function bar_info(box, vertical)
	if IMGUI then
		local ok, W = pcall(require, "core.imgui.widgets.winscrollbar")
		if not ok or not W.info then return "no-port" end
		local i = W.info(box, vertical)
		if not i then return "hidden" end
		return string.format("bar %d,%d %dx%d line %d thumb %d..%d", i.x, i.y, i.w, i.h, i.line, i.thumb_top, i.thumb_bottom)
	end
	local sbi = ffi.new("SC_SBI"); sbi.cbSize = ffi.sizeof(sbi)
	local hw = hwnd_of(box)
	if user32.GetScrollBarInfo(hw, vertical and -5 or -6, sbi) == 0 then return "noinfo " .. tostring(hw) .. " " .. tostring(ffi.C.GetLastError and ffi.C.GetLastError()) end
	if bit.band(sbi.rgstate[0], 0x8000) ~= 0 then return "hidden" end -- STATE_SYSTEM_INVISIBLE
	if bit.band(sbi.rgstate[0], 0x1) ~= 0 then return "disabled" end
	local p = ffi.new("SC_POINT", sbi.rcScrollBar.left, sbi.rcScrollBar.top); user32.ScreenToClient(main_hwnd, p)
	return string.format("bar %d,%d %dx%d line %d thumb %d..%d", p.x, p.y, sbi.rcScrollBar.right - sbi.rcScrollBar.left,
		sbi.rcScrollBar.bottom - sbi.rcScrollBar.top, sbi.dxyLineButton, sbi.xyThumbTop, sbi.xyThumbBottom)
end

local boxes, names = {}, {}
local cbs = {}
local function report(label)
	for i, box in ipairs(boxes) do
		local c = iup.GetChild(box, 0)
		local cx, cy, cw, ch = rect(c)
		local bx, by, bw, bh = rect(box)
		say(label, names[i], "box", bx .. "," .. by, bw .. "x" .. bh,
			"DX", iup.GetAttribute(box, "DX"), "DY", iup.GetAttribute(box, "DY"),
			"XMAX", iup.GetAttribute(box, "XMAX"), "YMAX", iup.GetAttribute(box, "YMAX"),
			"POSX", iup.GetAttribute(box, "POSX"), "POSY", iup.GetAttribute(box, "POSY"),
			"child", cx .. "," .. cy, cw .. "x" .. ch)
		say(label, names[i], "vbar", bar_info(box, true))
		say(label, names[i], "hbar", bar_info(box, false))
	end
	if #cbs > 0 then say(label, "callbacks", table.concat(cbs, " ")); cbs = {} end
end

local function column(n, prefix)
	local v = iup.vbox{ GAP = "4", MARGIN = "6x6" }
	for i = 1, n do
		iup.Append(v, iup.flatbutton{ TITLE = prefix .. " " .. i, RASTERSIZE = "220x28", BGCOLOR = "230 230 240" })
	end
	return v
end

-- box A: SCROLLBAR=VERTICAL, as the media server page uses it
local a = iup.scrollbox{ column(30, "row"), SCROLLBAR = "VERTICAL", RASTERSIZE = "260x300" }
-- box B: both bars, content wider and taller
local wide = iup.vbox{ iup.hbox{ iup.flatbutton{ TITLE = "wide", RASTERSIZE = "500x40" } }, column(20, "item"), MARGIN = "6x6" }
local b = iup.scrollbox{ wide, RASTERSIZE = "260x300" }
-- box C: holds everything (no bar shown)
local c = iup.scrollbox{ column(3, "few"), RASTERSIZE = "260x300" }
-- box D: a huge child (minimum thumb); box E: shorter than two arrow buttons
local dd = iup.scrollbox{ iup.vbox{ iup.flatbutton{ TITLE = "huge", RASTERSIZE = "100x30000" } }, SCROLLBAR = "VERTICAL", RASTERSIZE = "130x120", EXPAND = "NO" }
local ee = iup.scrollbox{ iup.vbox{ iup.flatbutton{ TITLE = "e", RASTERSIZE = "60x300" } }, SCROLLBAR = "VERTICAL", RASTERSIZE = "100x30", EXPAND = "NO" }
boxes, names = { a, b, c, dd, ee }, { "A", "B", "C", "D", "E" }
for i, box in ipairs(boxes) do
	local n = names[i]
	box.layoutupdate_cb = function() cbs[#cbs + 1] = n .. ":LAYOUTUPDATE" end
end
local ml = iup.text{ MULTILINE = "YES", RASTERSIZE = "200x120", VALUE = (string.rep("line of text that is long enough to wrap or scroll\n", 30)) }
local list = iup.list{ RASTERSIZE = "200x120" }
for i = 1, 40 do list[tostring(i)] = "list item " .. i end
dlg = iup.dialog{ iup.vbox{ iup.hbox{ a, b, c, GAP = "10" }, iup.hbox{ ml, list, dd, ee, GAP = "10" }, MARGIN = "10x10", GAP = "10" },
	TITLE = "scroll probe", RASTERSIZE = "900x520", BGCOLOR = "240 240 240" }
-- IUP's RASTERSIZE is the window, the host's the client: give the host IUP's client
if IMGUI then dlg.rastersize = os.getenv("LUNAR_SCROLL_CLIENT") or "884x481" end

local step = 0
local shot = 0
local function snap(label) shot = shot + 1; save_bmp(string.format("%s/scroll-%s-%02d-%s.bmp", out_dir, tag, shot, label)) end
-- the scenario: each entry runs on one tick; reports run on the tick after an input
local A_x, A_y, A_w, A_h
local seq = {
	function() report("start"); snap("start")
		say("multiline", "rect", rect(ml)); say("multiline", "vbar", bar_info(ml, true), "hbar", bar_info(ml, false))
		say("list", "rect", rect(list)); say("list", "vbar", bar_info(list, true), "hbar", bar_info(list, false)) end,
	function() local x, y, w, h = rect(a); A_x, A_y, A_w, A_h = x, y, w, h; mouse("move", x + w - 8, y + 200, 7, hwnd_of(a)) end,
	function() end, function() end, function() end,
	function() snap("hover-track"); mouse("move", A_x + A_w - 8, A_y + 40, 7, hwnd_of(a)) end,
	function() end, function() end, function() end,
	function() snap("hover-thumb"); mouse("move", A_x + 40, A_y + 40) end,
	function() end, function() end, function() end, function() end, function() end, function() end,
	function() snap("rest-again") end,
	function() local x, y, w, h = rect(a); A_x, A_y, A_w, A_h = x, y, w, h; mouse("move", x + 60, y + 100); mouse("wheel", x + 60, y + 100) end,
	function() report("wheel1") end,
	-- line down: the bottom arrow of A's bar
	function() local hw = hwnd_of(a); mouse("down", A_x + A_w - 8, A_y + A_h - 8, 7, hw); mouse("up", A_x + A_w - 8, A_y + A_h - 8, 7, hw) end,
	function() report("linedown") end,
	-- page down: the track just above the bottom arrow
	function() local hw = hwnd_of(a); mouse("down", A_x + A_w - 8, A_y + A_h - 30, 7, hw); mouse("up", A_x + A_w - 8, A_y + A_h - 30, 7, hw) end,
	function() report("pagedown"); snap("pagedown") end,
	-- SCROLLTO and the attributes
	function() iup.SetAttribute(a, "SCROLLTO", "BOTTOM") end,
	function() report("scrolltobottom"); snap("bottom") end,
	function() iup.SetAttribute(a, "POSY", "37") end,
	function() report("posy37") end,
	function() iup.SetAttribute(a, "SCROLLTO", "TOP") end,
	function() report("scrolltotop") end,
	-- drag the content: press on A's own background (the vbox margin, left of the buttons)
	function() mouse("move", A_x + 3, A_y + 150); mouse("down", A_x + 3, A_y + 150) end,
	function() mouse("move", A_x + 3, A_y + 100, nil, nil, true) end,
	function() mouse("up", A_x + 3, A_y + 100) end,
	function() report("contentdrag") end,
	-- the thumb: press on it, move 40 px down, release
	function() local hw = hwnd_of(a); mouse("down", A_x + A_w - 8, A_y + 25, 7, hw)
		local sx, sy = screen(A_x + A_w - 8, A_y + 65)
		local p = ffi.new("SC_POINT", sx, sy)
		if not IMGUI then user32.ScreenToClient(hw, p); user32.PostMessageA(hw, WM.move, 1, lp(p.x, p.y)); user32.PostMessageA(hw, WM.up, 0, lp(p.x, p.y))
		else mouse("move", A_x + A_w - 8, A_y + 65, nil, nil, true); mouse("up", A_x + A_w - 8, A_y + 65) end end,
	function() report("thumbdrag"); snap("thumbdrag") end,
	-- box B horizontal arrow
	function() local x, y, w, h = rect(b); local hw = hwnd_of(b); mouse("down", x + w - 25, y + h - 8, 6, hw); mouse("up", x + w - 25, y + h - 8, 6, hw) end,
	function() report("hlinedown") end,
	-- resizing a box so the content fits hides the bar
	function() iup.SetAttribute(a, "RASTERSIZE", "260x480"); iup.Refresh(dlg) end,
	function() report("tall") end,
	function() snap("end") end,
}

local real = iup.MainLoop
local function run()
	local t = iup.timer{ time = 250 }
	function t:action_cb()
		step = step + 1
		local ok, err = pcall(function()
			if step == 4 then
				main_hwnd = hwnd_of(dlg)
				say("clientsize", iup.GetAttribute(dlg, "CLIENTSIZE"))
			elseif step > 6 then
				local f = seq[step - 6]
				if f then f() else out:close(); os.exit(0) end
			end
		end)
		if not ok then say("ERR", err) end
		return iup.DEFAULT
	end
	t.run = "YES"
	real()
end
dlg:showxy(0, 0)
run()
os.exit(0)
