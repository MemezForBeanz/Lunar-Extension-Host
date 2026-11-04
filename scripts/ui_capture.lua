-- scripts/ui_capture.lua — start Lunar normally, walk every tab, and save a PNG-ready
-- bitmap of the main window for each one. Used for before/after design review.
--
-- Run (Windows dev build):
--   Lunar scripts/ui_capture.lua <out_dir> [prefix]
-- Point %APPDATA% at a scratch folder first so the run leaves real settings alone.
-- Output is 32-bit BMP (<out_dir>/<prefix>-NN-<tab>.bmp); convert with any tool.

local iup = require("iup")
local ffi = require("ffi")

local out_dir = (arg and arg[1]) or "."
local prefix = (arg and arg[2]) or "shot"

ffi.cdef[[
typedef struct { long left, top, right, bottom; } CAP_RECT;
typedef struct { uint32_t biSize; long biWidth, biHeight; uint16_t biPlanes, biBitCount;
  uint32_t biCompression, biSizeImage; long biXPelsPerMeter, biYPelsPerMeter;
  uint32_t biClrUsed, biClrImportant; } CAP_BMIH;
int GetClientRect(void*, CAP_RECT*);
int GetWindowRect(void*, CAP_RECT*);
int BitBlt(void*, int, int, int, int, void*, int, int, unsigned);
void* GetDC(void*);
int ReleaseDC(void*, void*);
int PrintWindow(void*, void*, unsigned);
void* CreateCompatibleDC(void*);
void* CreateCompatibleBitmap(void*, int, int);
void* SelectObject(void*, void*);
int GetDIBits(void*, void*, unsigned, unsigned, void*, CAP_BMIH*, unsigned);
int DeleteObject(void*);
int DeleteDC(void*);
]]
local user32, gdi32 = ffi.load("user32"), ffi.load("gdi32")

-- from_screen copies what is really on screen: a popup, and an edit control's cue
-- banner, only paint for WM_PAINT, which PrintWindow does not send.
local function save_bmp(hwnd, path, from_screen)
	local rc = ffi.new("CAP_RECT")
	if from_screen then user32.GetWindowRect(hwnd, rc) else user32.GetClientRect(hwnd, rc) end
	local w, h = rc.right - rc.left, rc.bottom - rc.top
	local screen = user32.GetDC(from_screen and nil or hwnd)
	local mem = gdi32.CreateCompatibleDC(screen)
	local bmp = gdi32.CreateCompatibleBitmap(screen, w, h)
	local old = gdi32.SelectObject(mem, bmp)
	if from_screen then
		gdi32.BitBlt(mem, 0, 0, w, h, screen, rc.left, rc.top, 0x00CC0020) -- SRCCOPY
	else
		user32.PrintWindow(hwnd, mem, 3) -- PW_CLIENTONLY | PW_RENDERFULLCONTENT
	end
	gdi32.SelectObject(mem, old)
	local bi = ffi.new("CAP_BMIH")
	bi.biSize, bi.biWidth, bi.biHeight, bi.biPlanes, bi.biBitCount = ffi.sizeof(bi), w, h, 1, 32
	local bytes = w * h * 4
	local px = ffi.new("uint8_t[?]", bytes)
	gdi32.GetDIBits(mem, bmp, 0, h, px, bi, 0)
	gdi32.DeleteObject(bmp)
	gdi32.DeleteDC(mem)
	user32.ReleaseDC(from_screen and nil or hwnd, screen)
	local file = assert(io.open(path, "wb"))
	local function le(n, count)
		local t = {}
		for i = 1, count do t[i] = string.char(bit.band(bit.rshift(n, (i - 1) * 8), 255)) end
		return table.concat(t)
	end
	file:write("BM", le(54 + bytes, 4), le(0, 4), le(54, 4))
	file:write(ffi.string(bi, ffi.sizeof(bi)):sub(1, 40), ffi.string(px, bytes))
	file:close()
end

local function class(h) return iup.GetClassName(h) end

-- Every leaf page, as the chain of (strip, position) steps that reveals it.
local function leaves(strip, path, out)
	local i, page = 0, iup.GetChild(strip, 0)
	while page do
		local step = {}
		for _, s in ipairs(path) do step[#step + 1] = s end
		step[#step + 1] = { strip = strip, pos = i }
		if class(page) == "flattabs" then
			leaves(page, step, out)
		else
			out[#out + 1] = { path = step,
				title = iup.GetAttribute(strip, "TABTITLE" .. i) or ("tab" .. i) }
		end
		i = i + 1
		page = iup.GetChild(strip, i)
	end
	return out
end

local function find_strip(h)
	if class(h) == "flattabs" then return h end
	local i, child = 0, iup.GetChild(h, 0)
	while child do
		local found = find_strip(child)
		if found then return found end
		i = i + 1
		child = iup.GetChild(h, i)
	end
end

local function main_dialog()
	local focus = iup.GetFocus()
	local d = focus and iup.GetDialog(focus)
	if d and find_strip(d) then return d end
	local names = { iup.GetAllDialogs() }
	if type(names[1]) == "table" then names = names[1] end
	for _, name in ipairs(names) do
		d = iup.GetHandle(name)
		if d and iup.GetAttribute(d, "VISIBLE") == "YES" and find_strip(d) then return d end
	end
end

-- Give every empty list some rows, so scrollbars, row height and selection show up in
-- a run with no real data behind it.
local function fill_lists(h)
	-- Screenshots leave this machine, and org packs prefill internal hosts and addresses.
	if class(h) == "text" then
		local value = iup.GetAttribute(h, "VALUE") or ""
		if value:match("^\\\\") then
			iup.SetAttribute(h, "VALUE", "\\\\server\\share")
		elseif value:match("%d+%.%d+%.%d+%.%d+") then
			iup.SetAttribute(h, "VALUE", "https://backend.example:8000")
		end
	end
	if class(h) == "flatlist" and (tonumber(iup.GetAttribute(h, "COUNT")) or 0) == 0
		and iup.GetAttribute(h, "THEMEROLE") ~= "palette_list" then
		for i = 1, 40 do iup.SetAttribute(h, tostring(i), string.format("sample-item-%02d", i)) end
		iup.SetAttribute(h, "VALUE", "2")
	end
	local i, child = 0, iup.GetChild(h, 0)
	while child do
		fill_lists(child)
		i = i + 1
		child = iup.GetChild(h, i)
	end
end

local real_mainloop = iup.MainLoop
iup.MainLoop = function()
	local state, dlg, pages, index = 0, nil, nil, 1
	local scene = 0

	-- After the tabs: the command bar open, then two tabs side by side.
	local function extra_scene()
		local shell = rawget(_G, "LUNAR_DEV_SHELL")
		if not shell then return false end
		scene = scene + 1
		local IupFFI = require("core.classes.IupFFI")
		local function snap(name)
			save_bmp(ffi.cast("void*", IupFFI.getptr(IupFFI.ptr(dlg), "HWND")),
				string.format("%s/%s-%s.bmp", out_dir, prefix, name))
		end
		if scene == 1 then
			shell.palette:open("")
		elseif scene == 2 then
			local palette_dlg = shell.palette._dialog
			save_bmp(ffi.cast("void*", IupFFI.getptr(IupFFI.ptr(palette_dlg), "HWND")),
				string.format("%s/%s-90-palette.bmp", out_dir, prefix), true)
			shell.palette:close()
		elseif scene == 3 then
			local groups = shell.groups()
			local pages_now = groups:leaves()
			shell.panes:move(pages_now[3] or pages_now[1], "right")
			if pages_now[4] then shell.panes:move(pages_now[4], "bottom") end
		elseif scene == 4 then
			snap("91-split")
			return false
		end
		return true
	end

	local t = iup.timer({ time = 900 })
	local step
	function t:action_cb()
		local ok, err = pcall(step, self)
		if not ok then
			io.stderr:write("ui_capture: ", tostring(err), string.char(10))
			iup.ExitLoop()
			return iup.CLOSE
		end
		return err
	end
	function step(self)
		state = state + 1
		if state < 3 then return iup.DEFAULT end
		if not dlg then
			dlg = main_dialog()
			if not dlg then return iup.DEFAULT end
			pages = leaves(find_strip(dlg), {}, {})
			fill_lists(dlg)
			for _, p in ipairs(pages) do
				for _, s in ipairs(p.path) do iup.SetAttribute(s.strip, "VALUEPOS", tostring(s.pos)) end
			end
			return iup.DEFAULT
		end
		local page = pages[math.ceil(index / 2)]
		if not page then
			if extra_scene() then return iup.DEFAULT end
			self.run = "NO"
			iup.ExitLoop()
			return iup.CLOSE
		end
		if index % 2 == 1 then
			for _, s in ipairs(page.path) do iup.SetAttribute(s.strip, "VALUEPOS", tostring(s.pos)) end
		else
			local slug = page.title:lower():gsub("[^%w]+", "-")
			local IupFFI = require("core.classes.IupFFI")
			save_bmp(ffi.cast("void*", IupFFI.getptr(IupFFI.ptr(dlg), "HWND")), string.format("%s/%s-%02d-%s.bmp",
				out_dir, prefix, index / 2, slug))
		end
		index = index + 1
		return iup.DEFAULT
	end
	t.run = "YES"
	return real_mainloop()
end

local ok, err = pcall(dofile, (LUNAR_SOURCE_DIR or ".") .. "/src/lua/core/main.lua")
if not ok then
	io.stderr:write("ui_capture: ", tostring(err), string.char(10))
	os.exit(1)
end
