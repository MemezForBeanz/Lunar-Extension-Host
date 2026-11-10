-- scripts/ui_tour.lua -- open every interface the app has and photograph it, on either build.
--
--   Lunar scripts/ui_tour.lua <out_dir>
--
-- Runs on the IUP build and on the ImGui build alike (a hidden desktop, see
-- D:\lunar-council\tools\hcap.ps1), so each interface ends up as a pair of shots named
-- the same way:
--
--   * every tool page (`<build>__page-<page>.bmp`);
--   * every control on every page whose click opens a dialog, a popup, a menu or a drop
--     list: it is clicked with real window messages and its real callbacks, and what it
--     opened is shot (`<build>__<page>--<control>-<hash>[-wN].bmp`), its layout dumped,
--     then closed;
--   * every item of the application's menus (File, Help, extensions).
--
-- Message boxes, native file pickers and browsers are answered with "cancel" so nothing
-- blocks a run nobody watches. Writes <out_dir>/tour-<build>.tsv:
--   O <key> <page> <path> <label> <what opened>     one interface (key = shot name)
--   T <key> <path> <class> <x> <y> <w> <h> <label>  an element of what opened (dialog px)
--   X <key> <error>                                 a callback failed
local iup = require("iup")
local ffi = require("ffi")

-- This checkout's Lua, whichever build runs the script (as scripts/ui_probe.lua).
do
	local here = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
	local root = here:match("^(.*)/scripts/[^/]+$")
	if root and root ~= "" then
		LUNAR_SOURCE_DIR = root
		local mine = root .. "/src/lua/?.lua;" .. root .. "/src/lua/?/init.lua"
		table.insert(package.loaders, 2, function(name)
			local file = package.searchpath(name, mine)
			if not file then return nil end
			return assert(loadfile(file))
		end)
		for name in pairs(package.preload) do
			local f = io.open(root .. "/src/lua/" .. name:gsub("%.", "/") .. ".lua", "r")
			if f then f:close(); package.preload[name] = nil end
		end
	end
end

local IMGUI = rawget(iup, "_IMGUI") == true
local BUILD = IMGUI and "imgui" or "iup"
local out_dir = (arg and arg[1]) or "."
local out = assert(io.open(out_dir .. "/tour-" .. BUILD .. ".tsv", "w"))
local function emit(...)
	local t = { ... }
	for i = 1, #t do t[i] = tostring(t[i]):gsub("[\r\n\t]+", " ") end
	out:write(table.concat(t, "\t"), "\n"); out:flush()
end

ffi.cdef[[
typedef struct { long x, y; } TOUR_POINT;
typedef struct { long left, top, right, bottom; } TOUR_RECT;
typedef struct { uint32_t biSize; long biWidth, biHeight; uint16_t biPlanes, biBitCount;
  uint32_t biCompression, biSizeImage; long biXPelsPerMeter, biYPelsPerMeter;
  uint32_t biClrUsed, biClrImportant; } TOUR_BMIH;
typedef int (__stdcall *TOUR_ENUM)(void*, intptr_t);
int ClientToScreen(void*, TOUR_POINT*);
int ScreenToClient(void*, TOUR_POINT*);
void* ChildWindowFromPointEx(void*, TOUR_POINT, unsigned);
int PostMessageA(void*, unsigned, uintptr_t, intptr_t);
int ShowWindow(void*, int);
int MoveWindow(void*, int, int, int, int, int);
int IsWindowVisible(void*);
int EnumThreadWindows(uint32_t, TOUR_ENUM, intptr_t);
int GetWindowRect(void*, TOUR_RECT*);
int GetClientRect(void*, TOUR_RECT*);
int GetClassNameA(void*, char*, int);
int GetWindowTextA(void*, char*, int);
int EndMenu(void);
void* GetDC(void*);
int ReleaseDC(void*, void*);
int PrintWindow(void*, void*, unsigned);
void* CreateCompatibleDC(void*);
void* CreateCompatibleBitmap(void*, int, int);
void* SelectObject(void*, void*);
int BitBlt(void*, int, int, int, int, void*, int, int, unsigned);
int GetDIBits(void*, void*, unsigned, unsigned, void*, TOUR_BMIH*, unsigned);
int DeleteObject(void*);
int DeleteDC(void*);
]]
pcall(ffi.cdef, "uint32_t GetCurrentThreadId(void);")
local user32, gdi32 = ffi.load("user32"), ffi.load("gdi32")

-- Nothing may wait for a person ---------------------------------------------------------------
iup.Message = function() end
iup.Alarm = function() return 2 end
iup.GetText = function() return nil end
iup.GetParam = function() return false end
iup.ListDialog = function() return -1 end
local NATIVE_DIALOGS = { filedlg = true, messagedlg = true, fontdlg = true, colordlg = true, progressdlg = false }
local real_popup = iup.Popup
iup.Popup = function(h, ...)
	local ok, cls = pcall(iup.GetClassName, h)
	if ok and NATIVE_DIALOGS[cls] then
		pcall(iup.SetAttribute, h, "STATUS", "-1")
		return iup.NOERROR or 0
	end
	return real_popup(h, ...)
end
pcall(function()
	local desktop = require("core.lib.desktop")
	for k, v in pairs(desktop) do
		if type(v) == "function" and (k:find("^open") or k:find("^reveal") or k:find("^launch")) then
			desktop[k] = function() return true end
		end
	end
end)

local errors = {}
if IMGUI then
	local Runtime = require("core.imgui.Runtime")
	local real = Runtime.warn
	Runtime.warn = function(msg) errors[#errors + 1] = tostring(msg); pcall(real, msg) end
	require("core.imgui.Element").hooks.error = function(el, name, err) errors[#errors + 1] = name .. ": " .. tostring(err) end
end

-- Helpers ------------------------------------------------------------------------------------
local function class(h) return iup.GetClassName(h) end
local function children(h)
	local list, i = {}, 0
	local c = iup.GetChild(h, 0)
	while c do list[#list + 1] = c; i = i + 1; c = iup.GetChild(h, i) end
	return list
end
local function walk(h, path, list)
	list[#list + 1] = { h = h, path = path }
	for i, c in ipairs(children(h)) do walk(c, path .. "/" .. class(c) .. "[" .. (i - 1) .. "]", list) end
	return list
end
local function visible(h)
	if IMGUI then return require("core.imgui.Runtime").isVisible(h) end
	return iup.GetAttribute(h, "VISIBLE") == "YES"
end
local function attr(h, name) local ok, v = pcall(iup.GetAttribute, h, name); return ok and v or nil end
local function label(h)
	for _, a in ipairs({ "TITLE", "TIP", "NAME", "THEMEROLE" }) do
		local v = attr(h, a)
		if v and v ~= "" then return v:gsub("[\r\n\t]", " "):sub(1, 40) end
	end
	return class(h)
end
local function slug(s) return (tostring(s or ""):lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", ""):sub(1, 32)) end
local function hash(s)
	local h = 5381
	for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
	return string.format("%04x", h % 65536)
end
local function rect(h, ox, oy)
	local sp, sz = attr(h, "SCREENPOSITION"), attr(h, "RASTERSIZE") or attr(h, "CURRENTSIZE")
	local x, y = (sp or ""):match("^(-?%d+),(-?%d+)")
	local w, ht = (sz or ""):match("^(%d+)x(%d+)")
	if not (x and w) then return nil end
	return tonumber(x) - ox, tonumber(y) - oy, tonumber(w), tonumber(ht)
end
local function hwnd_of(dlg)
	if IMGUI then return ffi.cast("void*", ffi.cast("uintptr_t", tonumber(require("core.imgui.Runtime").backend().window("hwnd")))) end
	local IupFFI = require("core.classes.IupFFI")
	return ffi.cast("void*", IupFFI.getptr(IupFFI.ptr(dlg), "HWND"))
end
local function client_origin(hwnd)
	local pt = ffi.new("TOUR_POINT", 0, 0)
	user32.ClientToScreen(hwnd, pt)
	return pt.x, pt.y
end

-- A window's own pixels (IUP): PrintWindow of the whole window, or its client area.
local function save_window(hwnd, path, client)
	local win = ffi.new("TOUR_RECT")
	user32.GetWindowRect(hwnd, win)
	local ww, wh = win.right - win.left, win.bottom - win.top
	if ww <= 0 or wh <= 0 then return end
	local x, y, w, h = 0, 0, ww, wh
	if client then
		local rc = ffi.new("TOUR_RECT"); user32.GetClientRect(hwnd, rc)
		local ox, oy = client_origin(hwnd)
		x, y, w, h = ox - win.left, oy - win.top, rc.right, rc.bottom
	end
	local screen = user32.GetDC(nil)
	local whole_dc, mem = gdi32.CreateCompatibleDC(screen), gdi32.CreateCompatibleDC(screen)
	local whole, bmp = gdi32.CreateCompatibleBitmap(screen, ww, wh), gdi32.CreateCompatibleBitmap(screen, w, h)
	local p1, p2 = gdi32.SelectObject(whole_dc, whole), gdi32.SelectObject(mem, bmp)
	user32.PrintWindow(hwnd, whole_dc, 2)
	gdi32.BitBlt(mem, 0, 0, w, h, whole_dc, x, y, 0x00CC0020)
	gdi32.SelectObject(whole_dc, p1); gdi32.SelectObject(mem, p2)
	local bi = ffi.new("TOUR_BMIH")
	bi.biSize, bi.biWidth, bi.biHeight, bi.biPlanes, bi.biBitCount = ffi.sizeof(bi), w, h, 1, 32
	local bytes = w * h * 4
	local px = ffi.new("uint8_t[?]", bytes)
	gdi32.GetDIBits(mem, bmp, 0, h, px, bi, 0)
	gdi32.DeleteObject(whole); gdi32.DeleteObject(bmp); gdi32.DeleteDC(whole_dc); gdi32.DeleteDC(mem)
	user32.ReleaseDC(nil, screen)
	local f = assert(io.open(path, "wb"))
	local function le(n, c) local t = {}; for i = 1, c do t[i] = string.char(bit.band(bit.rshift(n, (i - 1) * 8), 255)) end; return table.concat(t) end
	f:write("BM", le(54 + bytes, 4), le(0, 4), le(54, 4), ffi.string(bi, 40), ffi.string(px, bytes))
	f:close()
end

-- One callback for every enumeration (LuaJIT has a fixed number of callback slots).
local enum_list, enum_main
local enum_cb = ffi.cast("TOUR_ENUM", function(hwnd, _)
	if enum_list and hwnd ~= enum_main and user32.IsWindowVisible(hwnd) ~= 0 then
		local buf = ffi.new("char[64]")
		user32.GetClassNameA(hwnd, buf, 64)
		local cls = ffi.string(buf)
		if cls ~= "IME" and cls ~= "MSCTFIME UI" and not cls:find("^tooltips") then
			enum_list[#enum_list + 1] = { hwnd = hwnd, cls = cls, id = tostring(tonumber(ffi.cast("uintptr_t", hwnd))) }
		end
	end
	return 1
end)

-- What is open besides the main window: IUP's are windows of this thread; the ImGui host's
-- are dialogs and overlays drawn inside the main window.
local function open_things(main)
	local list = {}
	if IMGUI then
		local R = require("core.imgui.Runtime")
		for _, d in ipairs(R.dialogs()) do
			if d ~= R.mainDialog() and R.isVisible(d) then list[#list + 1] = { dialog = d, id = "d" .. tostring(d) } end
		end
		for _, o in ipairs(R.overlays()) do list[#list + 1] = { overlay = o, id = "o" .. tostring(o) } end
		return list
	end
	enum_list, enum_main = list, main
	user32.EnumThreadWindows(ffi.C.GetCurrentThreadId(), enum_cb, 0)
	enum_list = nil
	return list
end
local function dialog_of_hwnd(hwnd)
	local names = { iup.GetAllDialogs() }
	if type(names[1]) == "table" then names = names[1] end
	for _, name in ipairs(names) do
		local d = iup.GetHandle(name)
		if d and hwnd_of(d) == hwnd then return d end
	end
end

local function dump_tree(key, dlg)
	if not dlg then return end
	local ox, oy
	if IMGUI then
		ox, oy = rect(dlg, 0, 0)
	else
		ox, oy = client_origin(hwnd_of(dlg))
	end
	if not ox then return end
	for _, e in ipairs(walk(dlg, class(dlg), {})) do
		if visible(e.h) then
			local x, y, w, h = rect(e.h, ox, oy)
			if x then emit("T", key, e.path, class(e.h), x, y, w, h, label(e.h)) end
		end
	end
end

local function shoot_new(key, before, main, main_dlg)
	local seen = {}
	for _, b in ipairs(before) do seen[b.id] = true end
	local new = {}
	for _, n in ipairs(open_things(main)) do if not seen[n.id] then new[#new + 1] = n end end
	if #new == 0 then return new end
	local titles = {}
	if IMGUI then
		local R = require("core.imgui.Runtime")
		local B = R.backend()
		B.screenshot(out_dir .. "/" .. BUILD .. "__" .. key .. ".bmp")
		R.frame()
		for i, n in ipairs(new) do
			if n.dialog then
				local st = require("core.imgui.Element").state(n.dialog)
				local top = st.data.chrome and st.data.chrome.top or 0
				B.screenshot(out_dir .. "/" .. BUILD .. "__" .. key .. "-w" .. i .. ".bmp",
					st.data.ox or 0, (st.data.oy or 0) - top, st.w, st.h + top)
				R.frame()
				titles[#titles + 1] = "dialog:" .. tostring(attr(n.dialog, "TITLE"))
				dump_tree(key, n.dialog)
			else
				titles[#titles + 1] = "popup"
			end
		end
	else
		save_window(main, out_dir .. "/" .. BUILD .. "__" .. key .. ".bmp", true)
		for i, n in ipairs(new) do
			save_window(n.hwnd, out_dir .. "/" .. BUILD .. "__" .. key .. "-w" .. i .. ".bmp", false)
			local d = dialog_of_hwnd(n.hwnd)
			titles[#titles + 1] = (d and "dialog:" .. tostring(attr(d, "TITLE"))) or ("window:" .. n.cls)
			if d then dump_tree(key, d) end
		end
	end
	emit("O", key, table.concat(titles, "; "))
	return new
end

local function close_new(new)
	for i = #new, 1, -1 do
		local n = new[i]
		if n.overlay then pcall(function() n.overlay:close() end)
		elseif n.dialog then pcall(iup.Hide, n.dialog)
		elseif n.hwnd then
			if n.cls == "#32768" then user32.EndMenu()
			else
				local d = dialog_of_hwnd(n.hwnd)
				if d then pcall(iup.Hide, d) else user32.PostMessageA(n.hwnd, 0x0010, 0, 0) end -- WM_CLOSE
			end
		end
	end
	if IMGUI then
		local R = require("core.imgui.Runtime")
		for i = #R.overlays(), 1, -1 do pcall(function() R.overlays()[i]:close() end) end
	end
end

local function lparam(x, y) return bit.bor(bit.band(x, 0xFFFF), bit.lshift(bit.band(y, 0xFFFF), 16)) end
local function click(hwnd, x, y)
	local target, px, py = hwnd, x, y
	if not IMGUI then
		local pt = ffi.new("TOUR_POINT", x, y)
		while true do
			local child = user32.ChildWindowFromPointEx(target, pt, 1 + 4)
			if child == nil or child == target then break end
			local s = ffi.new("TOUR_POINT", pt.x, pt.y)
			user32.ClientToScreen(target, s); user32.ScreenToClient(child, s)
			target, pt = child, s
		end
		px, py = pt.x, pt.y
	end
	user32.PostMessageA(target, 0x0200, 0, lparam(px, py))
	user32.PostMessageA(target, 0x0201, 1, lparam(px, py))
	user32.PostMessageA(target, 0x0202, 0, lparam(px, py))
end

-- Pages (as ui_capture finds them) ---------------------------------------------------------------
local function leaves(strip, path, acc)
	for i, page in ipairs(children(strip)) do
		local step = {}
		for _, s in ipairs(path) do step[#step + 1] = s end
		step[#step + 1] = { strip = strip, pos = i - 1 }
		if class(page) == "flattabs" then leaves(page, step, acc)
		else acc[#acc + 1] = { path = step, title = attr(strip, "TABTITLE" .. (i - 1)) or ("tab" .. i) } end
	end
	return acc
end
local function find_strip(h)
	local role = attr(h, "THEMEROLE")
	if role == "titlebar_tabs" or role == "tool_rail" then return nil end
	if class(h) == "flattabs" then return h end
	for _, c in ipairs(children(h)) do local f = find_strip(c); if f then return f end end
end
local function main_dialog()
	if IMGUI then return require("core.imgui.Runtime").mainDialog() end
	local focus = iup.GetFocus()
	local d = focus and iup.GetDialog(focus)
	if d and find_strip(d) then return d end
	local names = { iup.GetAllDialogs() }
	if type(names[1]) == "table" then names = names[1] end
	for _, name in ipairs(names) do
		d = type(name) == "string" and iup.GetHandle(name) or name
		if d and attr(d, "VISIBLE") == "YES" and find_strip(d) then return d end
	end
end

local CLICK_CBS = { "action", "flat_action", "button_cb", "flat_button_cb", "dropshow_cb", "extrabutton_cb" }
-- Controls a tour must not press: they end the session or reach the outside world.
local SKIP = { "quit", "exit", "restart", "reload", "sign out", "uninstall", "update now", "install update" }
local function skipped(text)
	text = tostring(text or ""):lower()
	for _, s in ipairs(SKIP) do if text:find(s, 1, true) then return true end end
	return false
end

-- Menu items: the app menu's File, Help and extension menus.
local function menu_items(acc, h, trail)
	if not h then return acc end
	for _, c in ipairs(children(h)) do
		local cls = class(c)
		local title = attr(c, "TITLE") or ""
		if cls == "item" then acc[#acc + 1] = { h = c, title = trail .. title }
		else menu_items(acc, c, (cls == "submenu" and trail .. title .. " > ") or trail) end
	end
	return acc
end

-- The run ----------------------------------------------------------------------------------------
local commands_reg
-- Run fn from its own one-shot timer: a modal dialog it opens runs a nested loop inside
-- that timer's callback, and the tour's timer keeps firing to shoot and close it.
local function later(fn)
	local t = iup.timer({ time = 10 })
	function t:action_cb()
		self.run = "NO"
		fn()
		return iup.DEFAULT
	end
	t.run = "YES"
end
-- LUNAR_TOUR_MATCH="a|b|c": only entries whose title contains one of the words
local function tour_match(title)
	local only = os.getenv("LUNAR_TOUR_MATCH")
	if not only then return true end
	for word in only:gmatch("[^|]+") do if title:find(word, 1, true) then return true end end
	return false
end
local real_mainloop = iup.MainLoop
iup.MainLoop = function()
	local dlg, hwnd, pages, page_i, queue, qi = nil, nil, nil, 0, nil, 1
	local phase, ticks, current, before = "boot", 0, nil, nil
	local menus, mi = nil, 1
	local function show(page)
		for _, s in ipairs(page.path) do iup.SetAttribute(s.strip, "VALUEPOS", tostring(s.pos)) end
		local shell = rawget(_G, "LUNAR_DEV_SHELL")
		if shell and shell.sync_title_bar then pcall(shell.sync_title_bar) end
		if shell and shell.tab_changed then pcall(shell.tab_changed) end
		iup.Refresh(dlg)
	end
	local t = iup.timer({ time = 150 })
	function t:action_cb()
		local ok, err = pcall(function()
			ticks = ticks + 1
			if phase == "boot" then
				if ticks < 20 then return end
				dlg = main_dialog()
				if not dlg then return end
				hwnd = hwnd_of(dlg)
				if IMGUI then
					local B = require("core.imgui.Runtime").backend()
					B.file_dialog = function() return nil end
					B.message_box = function() return 2 end
					B.window("restore"); B.window("pos", 0, 0); B.window("size", 1400, 900)
				else
					user32.ShowWindow(hwnd, 9); user32.MoveWindow(hwnd, 0, 0, 1400, 900, 1)
				end
				pages = leaves(find_strip(dlg), {}, {})
				-- LUNAR_TOUR_ONLY=commands runs just the palette commands
				local only = os.getenv("LUNAR_TOUR_ONLY")
				phase, ticks = (only == "commands" or only == "menus") and only or "page", 0
				return
			end
			if phase == "page" then
				page_i = page_i + 1
				current = pages[page_i]
				if not current then phase, ticks = "menus", 0; return end
				show(current)
				phase, ticks = "page-shot", 0
				return
			end
			if phase == "page-shot" then
				if ticks < 5 then return end
				local key = "page-" .. slug(current.title)
				if IMGUI then
					require("core.imgui.Runtime").backend().screenshot(out_dir .. "/" .. BUILD .. "__" .. key .. ".bmp")
					require("core.imgui.Runtime").frame()
				else
					save_window(hwnd, out_dir .. "/" .. BUILD .. "__" .. key .. ".bmp", true)
				end
				emit("O", key, current.title, "", "page", "page")
				local ox, oy = client_origin(hwnd)
				queue = {}
				for _, e in ipairs(walk(dlg, class(dlg), {})) do
					local has = false
					for _, n in ipairs(CLICK_CBS) do
						local okf, f = pcall(function() return e.h[n] end)
						if okf and type(f) == "function" then has = true end
					end
					if has and visible(e.h) and attr(e.h, "ACTIVE") ~= "NO" and not skipped(label(e.h)) then
						local x, y, w, h = rect(e.h, ox, oy)
						if x and w > 2 and h > 2 and x + w / 2 > 0 and y + h / 2 > 0 and x + w / 2 < 1400 and y + h / 2 < 900 then
							queue[#queue + 1] = { e = e, x = math.floor(x + w / 2), y = math.floor(y + h / 2) }
						end
					end
				end
				qi, phase = 1, "click"
				return
			end
			if phase == "click" then
				local q = queue[qi]
				if not q then phase = "page"; return end
				errors = {}
				before = open_things(hwnd)
				q.key = slug(current.title) .. "--" .. slug(label(q.e.h)) .. "-" .. hash(q.e.path)
				click(hwnd, q.x, q.y)
				phase, ticks = "settle", 0
				return
			end
			if phase == "settle" then
				if ticks < 6 then return end
				local q = queue[qi]
				local new = shoot_new(q.key, before, hwnd, dlg)
				if #new > 0 then emit("O", q.key, current.title, q.e.path, label(q.e.h), "") end
				for _, e in ipairs(errors) do emit("X", q.key, e) end
				close_new(new)
				qi = qi + 1
				show(current)
				phase, ticks = "click", 0
				return
			end
			if phase == "menus" then
				if not menus then
					local host = rawget(_G, "LUNAR_DEV_SHELL") and LUNAR_DEV_SHELL.host
					menus = {}
					for _, m in ipairs({ host and host.file_menu, host and host.help_menu, host and host.ext_menu }) do
						menu_items(menus, m, "")
					end
					show(pages[1])
				end
				local m = menus[mi]
				if not m then phase, mi, menus = "commands", 1, nil; return end
				mi = mi + 1
				emit("M", m.title)
				if skipped(m.title) then return end
				if not tour_match(m.title) then return end
				errors = {}
				before = open_things(hwnd)
				m.key = "menu--" .. slug(m.title) .. "-" .. hash(m.title)
				local f = m.h.action
				if type(f) == "function" then
					local item = m.h
					later(function()
						local okc, e = pcall(f, item)
						if not okc then errors[#errors + 1] = tostring(e) end
					end)
				end
				current = m
				phase, ticks = "menu-settle", 0
				return
			end
			if phase == "menu-settle" then
				if ticks < 6 then return end
				local new = shoot_new(current.key, before, hwnd, dlg)
				emit("O", current.key, "menu", "", current.title, #new > 0 and "opened" or "nothing")
				for _, e in ipairs(errors) do emit("X", current.key, e) end
				close_new(new)
				show(pages[1])
				phase, ticks = "menus", 0
				return
			end
			if phase == "commands" then
				-- Every command the palette offers (Lunar's own and the extensions').
				if not menus then
					local reg = rawget(_G, "LUNAR_DEV_SHELL") and LUNAR_DEV_SHELL.palette and LUNAR_DEV_SHELL.palette._registry
					menus = {}
					-- what the palette lists for an empty query: commands and providers' items
					local list = reg and select(1, reg:query("")) or {}
					local seen_titles = {}
					for k, item in pairs(list) do
						local title = type(item) == "table" and tostring(item.title or k)
						if title and item.run and not seen_titles[title] then
							seen_titles[title] = true
							menus[#menus + 1] = { item = item, title = title }
						end
					end
					table.sort(menus, function(a, b) return a.title < b.title end)
					commands_reg = reg
				end
				local m = menus[mi]
				if not m then phase = "done"; return end
				mi = mi + 1
				if skipped(m.title) or m.title:lower():find("theme", 1, true) or m.title:lower():find("light/dark", 1, true) then return end
				if not tour_match(m.title) then return end
				errors = {}
				before = open_things(hwnd)
				m.key = "cmd--" .. slug(m.title) .. "-" .. hash(m.title)
				local item = m.item
				later(function()
					local okc, res, why = pcall(commands_reg.run, commands_reg, item)
					if not okc then errors[#errors + 1] = tostring(res) elseif res == false and why then errors[#errors + 1] = tostring(why) end
				end)
				current = m
				phase, ticks = "command-settle", 0
				return
			end
			if phase == "command-settle" then
				if ticks < 6 then return end
				local new = shoot_new(current.key, before, hwnd, dlg)
				emit("O", current.key, "command", "", current.title, #new > 0 and "opened" or "nothing")
				for _, e in ipairs(errors) do emit("X", current.key, e) end
				close_new(new)
				show(pages[1])
				phase, ticks = "commands", 0
				return
			end
		end)
		if not ok then emit("X", "tour", tostring(err)) end
		if phase == "done" then
			self.run = "NO"
			out:close()
			-- a dialog's nested loop would swallow ExitLoop; the run is over either way
			os.exit(0)
		end
		return iup.DEFAULT
	end
	t.run = "YES"
	return real_mainloop()
end

local ok, err = pcall(dofile, (LUNAR_SOURCE_DIR or ".") .. "/src/lua/core/main.lua")
if not ok then emit("X", "main", tostring(err)); out:close(); os.exit(1) end
os.exit(0)
