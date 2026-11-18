-- scripts/ui_mechanics.lua -- the shell's behaviour under real window messages, on either
-- build: tab drag and drop, tab context menus, split drag, the rail, the terminal, the
-- command palette, host shortcuts, tooltips, focus traversal, text entry and the window
-- states. Each step posts input (mouse messages to the window under the point, key messages
-- to the focused window with the modifier state set through SetKeyboardState) and, some
-- ticks later, writes what the shell reports. Diff mechanics-iup.txt against
-- mechanics-imgui.txt.
--
--   Lunar scripts/ui_mechanics.lua <out_dir>
--
-- Run on a private desktop (D:\lunar-council\tools\hidden.ps1) with LUNAR_CAPTURE_CLIENT=1.
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
			local path = root .. "/src/lua/" .. name:gsub("%.", "/") .. ".lua"
			local f = io.open(path, "r")
			if f then f:close(); package.preload[name] = function(...) return assert(loadfile(path))(...) end end
		end
	end
end

local IMGUI = rawget(iup, "_IMGUI") == true
local out = assert(io.open(((arg and arg[1]) or ".") .. "/mechanics-" .. (IMGUI and "imgui" or "iup") .. ".txt", "w"))
local function say(...)
	local t = {}
	for i = 1, select("#", ...) do t[i] = tostring((select(i, ...))) end
	out:write(table.concat(t, " "), "\n"); out:flush()
end
if IMGUI then
	local R = require("core.imgui.Runtime")
	local rw = R.warn
	R.warn = function(m) say("WARN", (tostring(m):gsub("\n", " | "):sub(1, 600))); pcall(rw, m) end
	require("core.imgui.Element").hooks.error = function(el, name, e) say("CBERR", name, (tostring(e):gsub("\n", " | "):sub(1, 600))) end
end
iup.Message = function(t, m) say("MESSAGE", tostring(t), (tostring(m):gsub("\n", " | "))) end
-- Popup menus are recorded, not shown: a native menu's loop would hold the script.
local real_popup = iup.Popup
local popups = {}
iup.Popup = function(h, x, y)
	if iup.GetClassName(h) == "menu" then
		local items, i, c = {}, 0, iup.GetChild(h, 0)
		while c do
			local cls = iup.GetClassName(c)
			items[#items + 1] = cls == "separator" and "-" or tostring(iup.GetAttribute(c, "TITLE"))
			i = i + 1; c = iup.GetChild(h, i)
		end
		popups[#popups + 1] = table.concat(items, " | ")
		return iup.DEFAULT
	end
	return real_popup(h, x, y)
end

ffi.cdef[[
typedef struct { long x, y; } MC_POINT;
typedef struct { long left, top, right, bottom; } MC_RECT;
int ClientToScreen(void*, MC_POINT*);
int ScreenToClient(void*, MC_POINT*);
void* ChildWindowFromPointEx(void*, MC_POINT, unsigned);
int PostMessageA(void*, unsigned, uintptr_t, intptr_t);
intptr_t SendMessageA(void*, unsigned, uintptr_t, intptr_t);
void* GetFocus(void);
void* GetCapture(void);
int GetKeyboardState(uint8_t*);
int SetKeyboardState(uint8_t*);
int IsZoomed(void*);
int IsIconic(void*);
int GetClientRect(void*, MC_RECT*);
int GetWindowRect(void*, MC_RECT*);
int GetClassNameA(void*, char*, int);
int IsWindowVisible(void*);
typedef int (__stdcall *MC_ENUMPROC)(void*, intptr_t);
int EnumThreadWindows(unsigned, MC_ENUMPROC, intptr_t);
unsigned GetCurrentThreadId(void);
int OpenClipboard(void*);
int CloseClipboard(void);
int EmptyClipboard(void);
void* GetClipboardData(unsigned);
]]
local user32, kernel32 = ffi.load("user32"), ffi.load("kernel32")

local main_hwnd, dlg, shell
local function hwnd_of(h)
	if IMGUI then return ffi.cast("void*", ffi.cast("uintptr_t", tonumber(require("core.imgui.Runtime").backend().window("hwnd")))) end
	local IupFFI = require("core.classes.IupFFI")
	return ffi.cast("void*", IupFFI.getptr(IupFFI.ptr(h), "HWND"))
end
local function lp(x, y) return bit.bor(bit.band(x, 0xFFFF), bit.lshift(bit.band(y, 0xFFFF), 16)) end
local function target(x, y)
	local t, pt = main_hwnd, ffi.new("MC_POINT", x, y)
	-- a window holding the mouse capture gets every mouse message, as with a real pointer
	-- (on IUP the tab drag's layered overlay window would otherwise be under the point)
	local cap = user32.GetCapture()
	if not IMGUI and cap ~= nil then
		local s2 = ffi.new("MC_POINT", x, y); user32.ClientToScreen(main_hwnd, s2); user32.ScreenToClient(cap, s2)
		return cap, s2.x, s2.y
	end
	if not IMGUI then
		while true do
			local c = user32.ChildWindowFromPointEx(t, pt, 5)
			if c == nil or c == t then break end
			local s = ffi.new("MC_POINT", pt.x, pt.y); user32.ClientToScreen(t, s); user32.ScreenToClient(c, s)
			t, pt = c, s
		end
	end
	return t, pt.x, pt.y
end
local MSG = { move = 0x0200, down = 0x0201, up = 0x0202, dbl = 0x0203, rdown = 0x0204, rup = 0x0205 }
-- a mouse message at main-client (x, y); `held` keeps MK_LBUTTON in wParam
local function mouse(kind, x, y, held)
	local t, px, py = target(x, y)
	local wp = 0
	if kind == "down" or kind == "dbl" or held then wp = 1 end
	if kind == "rdown" then wp = 2 end
	if kind ~= "move" and os.getenv("LUNAR_MECH_TRACE") then
		local buf = ffi.new("char[64]"); user32.GetClassNameA(t, buf, 64)
		say("  post", kind, x, y, "->", ffi.string(buf), px, py)
	end
	user32.PostMessageA(t, MSG[kind], wp, lp(px, py))
end
local function click(x, y) mouse("move", x, y); mouse("down", x, y); mouse("up", x, y) end

-- Modifiers: IUP's drivers (and the host's window procedure) read GetKeyState, which a posted
-- message does not change; SetKeyboardState sets this thread's table for the keys that follow.
local function set_mods(mods)
	local ks = ffi.new("uint8_t[256]")
	user32.GetKeyboardState(ks)
	local function put(vk, on) ks[vk] = on and 0x80 or 0 end
	put(0x10, mods.shift); put(0xA0, mods.shift)
	put(0x11, mods.ctrl); put(0xA2, mods.ctrl)
	put(0x12, mods.alt); put(0xA4, mods.alt)
	user32.SetKeyboardState(ks)
end
local function key_target()
	if IMGUI then return main_hwnd end
	local f = user32.GetFocus()
	if f == nil or user32.IsWindowVisible(f) == 0 then return main_hwnd end
	return f
end
local pending_mods = nil
-- one key: WM_KEYDOWN (WM_SYSKEYDOWN with Alt), the character it types if any, WM_KEYUP
local function key(vk, mods, char)
	mods = mods or {}
	set_mods(mods)
	pending_mods = true
	local t = key_target()
	local down, up = mods.alt and 0x0104 or 0x0100, mods.alt and 0x0105 or 0x0101
	user32.PostMessageA(t, down, vk, 1)
	user32.PostMessageA(t, up, vk, bit.bor(1, 0xC0000000))
end
local function type_text(s)
	set_mods({})
	local t = key_target()
	for i = 1, #s do
		local c = s:byte(i)
		user32.PostMessageA(t, 0x0102, c, 1)
	end
end

local function find(h, pred)
	if not h then return nil end
	if pred(h) then return h end
	local i, c = 0, iup.GetChild(h, 0)
	while c do
		local f = find(c, pred); if f then return f end
		i = i + 1; c = iup.GetChild(h, i)
	end
end
local function visible(h)
	if IMGUI then return require("core.imgui.Runtime").isVisible(h) end
	local p = h
	while p do
		if iup.GetAttribute(p, "VISIBLE") == "NO" then return false end
		p = iup.GetParent(p)
	end
	return true
end
local function rect(h)
	local o = ffi.new("MC_POINT", 0, 0); user32.ClientToScreen(main_hwnd, o)
	local sp = iup.GetAttribute(h, "SCREENPOSITION")
	local x, y = tostring(sp):match("^(-?%d+),(-?%d+)")
	local w, hh = tostring(iup.GetAttribute(h, "RASTERSIZE")):match("^(%d+)x(%d+)")
	if not x or not w then return nil end
	return tonumber(x) - o.x, tonumber(y) - o.y, tonumber(w), tonumber(hh)
end
local function centre(h) local x, y, w, hh = rect(h); if not x then return nil end; return x + math.floor(w / 2), y + math.floor(hh / 2) end
local function label(h)
	if not h then return "nil" end
	local t = iup.GetAttribute(h, "TITLE") or iup.GetAttribute(h, "TIP") or iup.GetAttribute(h, "CUEBANNER") or iup.GetAttribute(h, "NAME") or ""
	return iup.GetClassName(h) .. "[" .. tostring(t):gsub("%s+", " "):sub(1, 40) .. "]"
end
local function titles(strip)
	local n, t = tonumber(iup.GetAttribute(strip, "COUNT")) or 0, {}
	for i = 0, n - 1 do t[#t + 1] = tostring(iup.GetAttribute(strip, "TABTITLE" .. i)) end
	return table.concat(t, " | ")
end
local function clipboard()
	if IMGUI then return require("core.imgui.Runtime").clipboard_get() end
	local ok, v = pcall(function()
		local cb = iup.clipboard({})
		local text = iup.GetAttribute(cb, "TEXT")
		iup.Destroy(cb)
		return text
	end)
	return ok and v or ("error: " .. tostring(v))
end
local function tooltip_visible()
	if IMGUI then
		local R = require("core.imgui.Runtime")
		return R.tipShown and R.tipShown() or "n/a"
	end
	local found = false
	local cb = ffi.cast("MC_ENUMPROC", function(h)
		local buf = ffi.new("char[64]")
		user32.GetClassNameA(h, buf, 64)
		if ffi.string(buf) == "tooltips_class32" and user32.IsWindowVisible(h) ~= 0 then found = true end
		return 1
	end)
	user32.EnumThreadWindows(kernel32.GetCurrentThreadId(), cb, 0)
	cb:free()
	return found
end
local function state(tag)
	local vl = shell.view_layout
	local f = iup.GetFocus()
	say(tag, "rail_collapsed", tostring(shell.rail and shell.rail._collapsed),
		"bars", tostring(vl and vl:barsVisible()), "terminal", tostring(vl and vl:terminalVisible()),
		"palette", tostring(shell.palette and shell.palette:isOpen()),
		"route", tostring(shell.host and shell.host.currentAddressURI and shell.host:currentAddressURI()),
		"focus", label(f))
end

-- the scenario ------------------------------------------------------------------------------
local strip, S = nil, {}
local steps = {}
local function step(wait, fn) steps[#steps + 1] = { wait = wait, fn = fn } end

step(1, function()
	shell = rawget(_G, "LUNAR_DEV_SHELL")
	dlg = iup.GetDialog(shell.groups():rootStrip())
	main_hwnd = hwnd_of(dlg)
	if IMGUI then local B = require("core.imgui.Runtime").backend(); B.window("restore"); B.window("size", 1384, 892)
	else iup.SetAttribute(dlg, "RASTERSIZE", "1400x900"); iup.Refresh(dlg) end
end)
step(6, function()
	strip = shell.groups():rootStrip()
	S.bar = find(dlg, function(h) return iup.GetClassName(h) == "flattabs" and iup.GetAttribute(h, "THEMEROLE") == "titlebar_tabs" and visible(h) end)
	local bx, by, bw, bh = rect(S.bar)
	S.bar_x, S.bar_y, S.bar_w, S.bar_h = bx, by, bw, bh
	say("title bar strip", label(S.bar), bx, by, bw, bh, "count", iup.GetAttribute(S.bar, "COUNT"), "titles", titles(S.bar))
	local probe = {}
	for px = 0, bw - 1, 20 do probe[#probe + 1] = px .. ":" .. tostring(iup.ConvertXYToPos(S.bar, px, math.floor(bh / 2))) end
	say("bar xy2pos", table.concat(probe, " "))
	say("root strip", label(strip), "count", iup.GetAttribute(strip, "COUNT"), "value", tostring(iup.GetAttribute(strip, "VALUEPOS")))
	say("titles", titles(strip))
	local x, y, w, h = rect(strip)
	say("strip rect", x, y, w, h)
	state("start")
	-- where each tab is: IupConvertXYToPos along the tab band
	probe = {}
	for px = 0, math.min(w - 1, 900), 30 do probe[#probe + 1] = px .. ":" .. tostring(iup.ConvertXYToPos(strip, px, 14)) end
	say("xy2pos", table.concat(probe, " "))
	S.strip_x, S.strip_y, S.strip_w = x, y, w
end)

-- 1. Tab drag within the strip: the third tab is pressed in its middle, moved left in 6 px
-- steps across the first tab's left half, released there. The order should become 3,1,2.
local function tab_span(pos)
	local first, last
	local mid = math.floor(S.bar_h / 2)
	for px = 0, S.bar_w - 1 do
		if iup.ConvertXYToPos(S.bar, px, mid) == pos then first = first or px; last = px end
	end
	return first, last
end
step(1, function()
	local a0, a1 = tab_span(0)
	local c0, c1 = tab_span(1)
	S.from = { S.bar_x + math.floor((c0 + c1) / 2), S.bar_y + math.floor(S.bar_h / 2) }
	S.to = { S.bar_x + a0 + 4, S.bar_y + math.floor(S.bar_h / 2) }
	say("drag tab 1 from", S.from[1], "to", S.to[1], "(tab 0 spans", a0, a1, "tab 1 spans", c0, c1, ")")
	-- trace the strip's callbacks for this gesture
	for _, name in ipairs({ "flat_button_cb", "flat_motion_cb", "rightclick_cb" }) do
		local f = S.bar[name]
		if type(f) == "function" and not S.traced then
			S.bar[name] = function(self_, ...)
				local a = { ... }
				for k = 1, #a do a[k] = tostring(a[k]) end
				if name ~= "flat_motion_cb" or (S.motions or 0) < 3 then say("  cb", name, table.concat(a, ",")) end
				if name == "flat_motion_cb" then S.motions = (S.motions or 0) + 1 end
				return f(self_, ...)
			end
		end
	end
	S.traced = true
	mouse("move", S.from[1], S.from[2]); mouse("down", S.from[1], S.from[2])
end)
for i = 1, 12 do
	step(1, function()
		local x = S.from[1] + math.floor((S.to[1] - S.from[1]) * i / 12)
		mouse("move", x, S.from[2], true)
	end)
end
step(1, function() mouse("up", S.to[1], S.to[2]) end)
step(12, function() say("1 tab reorder:", titles(strip), "| bar:", titles(S.bar)); state("1") end)

-- 2. Drag the (now) second tab onto the middle of the first: forms a group
step(1, function()
	local a0, a1 = tab_span(0)
	local b0, b1 = tab_span(1)
	S.from = { S.bar_x + math.floor((b0 + b1) / 2), S.bar_y + math.floor(S.bar_h / 2) }
	S.to = { S.bar_x + math.floor((a0 + a1) / 2), S.bar_y + math.floor(S.bar_h / 2) }
	mouse("move", S.from[1], S.from[2]); mouse("down", S.from[1], S.from[2])
end)
for i = 1, 12 do
	step(1, function() mouse("move", S.from[1] + math.floor((S.to[1] - S.from[1]) * i / 12), S.from[2], true) end)
end
step(1, function() mouse("up", S.to[1], S.to[2]) end)
step(14, function() say("2 tab onto tab:", titles(strip), "| bar:", titles(S.bar)); state("2") end)

-- 3. Right-click on the first tab: the context menu's items
step(1, function()
	local a0, a1 = tab_span(0)
	local x, y = S.bar_x + math.floor((a0 + a1) / 2), S.bar_y + math.floor(S.bar_h / 2)
	mouse("move", x, y); mouse("rdown", x, y); mouse("rup", x, y)
end)
step(6, function() say("3 tab menu:", popups[#popups] or "none"); popups = {} end)

-- 4. Host shortcuts: Ctrl+B (rail), Ctrl+` (terminal), Ctrl+, (settings), Ctrl+P (palette)
step(1, function() state("4 before"); key(0x42, { ctrl = true }) end)
step(4, function() state("4 after Ctrl+B"); key(0x42, { ctrl = true }) end)
step(4, function() state("4 after Ctrl+B again"); key(0xC0, { ctrl = true }) end)
step(6, function() state("4 after Ctrl+`") end)
-- 5. Terminal typing: the terminal input has the focus after the toggle
step(1, function() type_text("version") end)
step(2, function() say("5 terminal input", tostring(shell.terminal and shell.terminal._input and shell.terminal._input:text())); key(0x0D, {}) end)
step(6, function()
	local t = shell.terminal
	local text = t and t._buffer and select(1, t._buffer:snapshot()) or ""
	say("5 terminal transcript tail:", (tostring(text):gsub("\n", " / "):sub(-120)))
	state("5")
	key(0xC0, { ctrl = true })
end)
step(6, function() state("5 after Ctrl+` again"); key(0xBC, { ctrl = true }) end)
step(6, function() state("4 after Ctrl+,") end)
-- 6. Command palette: Ctrl+P, filter, Down, Enter
step(1, function() key(0x50, { ctrl = true }) end)
step(6, function()
	state("6 palette opened")
	type_text("toggle side")
end)
step(6, function()
	local p = shell.palette
	local items = {}
	for i, it in ipairs(p and p._items or {}) do if i <= 5 then items[#items + 1] = tostring(it.title or it.label or it.name or it.id) end end
	say("6 palette items:", #(p and p._items or {}), table.concat(items, " | "))
	key(0x28, {})
end)
step(3, function() say("6 palette after Down: selected", tostring(shell.palette and shell.palette._selected or shell.palette and shell.palette._index)); key(0x26, {}) end)
step(3, function() key(0x0D, {}) end)
step(6, function() state("6 after Enter") end)
step(1, function() key(0x42, { ctrl = true }) end) -- put the rail back
step(4, function() state("6 rail restored") end)
-- 7. Escape closes the palette
step(1, function() key(0x50, { ctrl = true }) end)
step(5, function() state("7 palette again"); key(0x1B, {}) end)
step(5, function() state("7 after Esc") end)

-- 8. Focus traversal: Settings page, the first text field, then Tab x6 and Shift+Tab x2
step(1, function() key(0xBC, { ctrl = true }) end)
step(8, function()
	local field = find(dlg, function(h) return iup.GetClassName(h) == "text" and visible(h) and iup.GetAttribute(h, "ACTIVE") ~= "NO" end)
	S.field = field
	say("8 first field", label(field), rect(field))
	if field then local x, y = centre(field); click(x, y) end
end)
step(4, function() state("8 clicked field") ; key(0x09, {}) end)
for i = 1, 5 do
	step(3, function() say("8 Tab", i, label(iup.GetFocus())); key(0x09, {}) end)
end
step(3, function() say("8 Tab", 6, label(iup.GetFocus())); key(0x09, { shift = true }) end)
step(3, function() say("8 Shift+Tab", 1, label(iup.GetFocus())); key(0x09, { shift = true }) end)
step(3, function() say("8 Shift+Tab", 2, label(iup.GetFocus())) end)

-- 9. Text entry in that field: type, Home, Shift+End, Ctrl+C, End, Ctrl+V, Left x3, BS
step(1, function()
	if not S.field then return end
	S.old_value = iup.GetAttribute(S.field, "VALUE")
	local x, y = centre(S.field); click(x, y)
end)
step(3, function() key(0x41, { ctrl = true }) end)
step(2, function() say("9 Ctrl+A selection", tostring(iup.GetAttribute(S.field, "SELECTIONPOS"))); key(0x2E, {}) end)
step(3, function() type_text("hello world") end)
step(3, function() say("9 typed", tostring(iup.GetAttribute(S.field, "VALUE")), "caret", tostring(iup.GetAttribute(S.field, "CARETPOS"))); key(0x24, {}) end)
step(2, function() key(0x23, { shift = true }) end)
step(2, function() say("9 selection", tostring(iup.GetAttribute(S.field, "SELECTIONPOS")), tostring(iup.GetAttribute(S.field, "SELECTEDTEXT"))); key(0x43, { ctrl = true }) end)
step(2, function() key(0x23, {}) end)
step(2, function() key(0x56, { ctrl = true }) end)
step(3, function() say("9 pasted", tostring(iup.GetAttribute(S.field, "VALUE")), "clipboard", tostring(clipboard())); key(0x25, {}); key(0x25, {}); key(0x25, {}) end)
step(2, function() key(0x08, {}) end)
step(3, function()
	say("9 after Left x3, BS", tostring(iup.GetAttribute(S.field, "VALUE")), "caret", tostring(iup.GetAttribute(S.field, "CARETPOS")))
	key(0x25, { ctrl = true })
end)
step(2, function() say("9 Ctrl+Left caret", tostring(iup.GetAttribute(S.field, "CARETPOS"))); key(0x5A, { ctrl = true }) end)
step(3, function() say("9 Ctrl+Z", tostring(iup.GetAttribute(S.field, "VALUE"))) end)
step(1, function() if S.field then iup.SetAttribute(S.field, "VALUE", S.old_value or "") end end)

-- 10. Tooltip: rest the pointer on a title-bar button
step(1, function()
	local b = find(dlg, function(h) return iup.GetClassName(h) == "flatbutton" and tostring(iup.GetAttribute(h, "TIP") or "") ~= "" and visible(h) end)
	S.tipbtn = b
	local x, y = centre(b)
	say("10 tip target", label(b))
	mouse("move", x - 2, y); mouse("move", x, y)
end)
step(12, function() say("10 tooltip shown after ~1.5 s", tostring(tooltip_visible())) end)

-- 10b. Menu bar keys: F10, then Esc; Alt+F (no menu bar letters in Lunar's custom bar?)
step(1, function() popups = {}; key(0x79, {}) end)
step(5, function() say("10b after F10: menus", #popups, popups[1] or "", "focus", label(iup.GetFocus())); key(0x1B, {}) end)
step(3, function() popups = {}; key(0x46, { alt = true }) end)
step(5, function() say("10b after Alt+F: menus", #popups, popups[1] or "", "focus", label(iup.GetFocus())) end)

-- 11. Window states
step(1, function()
	say("11 before: RASTERSIZE", iup.GetAttribute(dlg, "RASTERSIZE"), "MAXSIZE", tostring(iup.GetAttribute(dlg, "MAXSIZE")),
		"MINSIZE", tostring(iup.GetAttribute(dlg, "MINSIZE")), "SCREENSIZE", tostring(iup.GetGlobal("SCREENSIZE")),
		"FULLSIZE", tostring(iup.GetGlobal("FULLSIZE")))
	user32.PostMessageA(main_hwnd, 0x0112, 0xF030, 0) -- SC_MAXIMIZE
end)
step(8, function()
	local rc = ffi.new("MC_RECT"); user32.GetClientRect(main_hwnd, rc)
	say("11 maximized", user32.IsZoomed(main_hwnd), "client", rc.right, rc.bottom, "dlg", tostring(iup.GetAttribute(dlg, "MAXIMIZED")))
	user32.PostMessageA(main_hwnd, 0x0112, 0xF120, 0) -- SC_RESTORE
end)
step(8, function()
	local rc = ffi.new("MC_RECT"); user32.GetClientRect(main_hwnd, rc)
	say("11 restored", user32.IsZoomed(main_hwnd), "client", rc.right, rc.bottom)
	user32.PostMessageA(main_hwnd, 0x0112, 0xF020, 0) -- SC_MINIMIZE
end)
step(8, function()
	say("11 minimized", user32.IsIconic(main_hwnd))
	user32.PostMessageA(main_hwnd, 0x0112, 0xF120, 0)
end)
step(8, function()
	say("11 restored again", user32.IsIconic(main_hwnd), user32.IsZoomed(main_hwnd))
	-- WM_NCHITTEST along the edges: what a press there would start
	local wr = ffi.new("MC_RECT"); user32.GetWindowRect(main_hwnd, wr)
	local function ht(x, y) return tonumber(user32.SendMessageA(main_hwnd, 0x0084, 0, lp(x, y))) end
	local cx, cy = math.floor((wr.left + wr.right) / 2), math.floor((wr.top + wr.bottom) / 2)
	local o = ffi.new("MC_POINT", 0, 0); user32.ClientToScreen(main_hwnd, o)
	say("11 window", wr.left, wr.top, wr.right, wr.bottom, "client origin", o.x, o.y)
	local pts = {
		{ "left", o.x + 1, cy }, { "right", o.x + (wr.right - wr.left) - 20, cy }, { "top", cx, o.y + 1 },
		{ "bottom", cx, wr.bottom - 9 }, { "topleft", o.x + 1, o.y + 1 }, { "bottomright", wr.right - 9, wr.bottom - 9 },
		{ "caption", cx, o.y + 20 },
	}
	for _, p in ipairs(pts) do say("11 hittest", p[1], ht(p[2], p[3])) end
end)

-- 12. Split: move the second page to the right, drag the sash, double-click it
step(1, function()
	local main = shell.panes:strip("main")
	local page = main and iup.GetChild(main, 1)
	local ok, err = pcall(function() return shell.panes:move(page, "right") end)
	say("12 split", tostring(ok), tostring(err))
end)
step(8, function()
	local split = shell.panes._grid
	S.split = split
	local mx, my, mw, mh = rect(shell.panes:strip("main"))
	local rx = rect(shell.panes:strip("right"))
	say("12 grid VALUE", iup.GetAttribute(split, "VALUE"), "main", mx, my, mw, mh, "right x", tostring(rx))
	if not rx then return end
	-- the sash sits between the main strip's right edge and the right strip
	S.sash = { math.floor((mx + mw + rx) / 2), my + math.floor(mh / 2) }
	mouse("move", S.sash[1], S.sash[2]); mouse("down", S.sash[1], S.sash[2])
end)
for i = 1, 6 do step(1, function() mouse("move", S.sash[1] - 20 * i, S.sash[2], true) end) end
step(1, function() mouse("up", S.sash[1] - 120, S.sash[2]) end)
step(6, function()
	local mx, _, mw = rect(shell.panes:strip("main"))
	say("12 after sash drag -120: grid VALUE", iup.GetAttribute(S.split, "VALUE"), "main w", mw)
	local x = mx + mw + 3
	mouse("move", x, S.sash[2]); mouse("down", x, S.sash[2]); mouse("up", x, S.sash[2]); mouse("dbl", x, S.sash[2]); mouse("up", x, S.sash[2])
end)
step(6, function()
	local _, _, mw = rect(shell.panes:strip("main"))
	say("12 after sash double-click: grid VALUE", iup.GetAttribute(S.split, "VALUE"), "main w", mw)
	-- 13. pane focus and restore
	local ok = shell.panes:toggleFocus()
	say("13 focus", tostring(ok), "focused", tostring(shell.panes:isFocused()), "VALUE", iup.GetAttribute(S.split, "VALUE"))
end)
step(6, function()
	shell.panes:restoreFocus()
	say("13 restored", tostring(shell.panes:isFocused()), "VALUE", iup.GetAttribute(S.split, "VALUE"))
end)

local real_mainloop = iup.MainLoop
iup.MainLoop = function()
	local i, wait, tick = 0, 30, 0
	local t = iup.timer({ time = 125 })
	function t:action_cb()
		tick = tick + 1
		if pending_mods then set_mods({}); pending_mods = nil end
		if wait > 0 then wait = wait - 1; return iup.DEFAULT end
		i = i + 1
		local s = steps[i]
		if not s then out:close(); os.exit(0) end
		local ok, err = pcall(s.fn)
		if not ok then say("ERR step", i, tostring(err)) end
		wait = s.wait
		return iup.DEFAULT
	end
	t.run = "YES"
	return real_mainloop()
end
local here = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
local root = here:match("^(.*)/scripts/[^/]+$") or LUNAR_SOURCE_DIR
local ok, err = pcall(dofile, root .. "/src/lua/core/main.lua")
if not ok then say("main.lua:", tostring(err)); out:close(); os.exit(1) end
os.exit(0)
