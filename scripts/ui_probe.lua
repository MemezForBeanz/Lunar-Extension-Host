-- scripts/ui_probe.lua -- walk every tool page, record where each control sits, and click
-- every control that has a click callback through real window messages. The callbacks are
-- recorded instead of run, so a click never navigates away or starts work.
--
--   Lunar scripts/ui_probe.lua <out.tsv>
--
-- Runs on the IUP build and on the ImGui build alike; diff the two files with
-- scripts/ui_probe_diff.lua. Run it on a hidden desktop (D:\lunar-council\tools\hidden.ps1):
-- the clicks are posted messages, but a window on the user's screen would still flash.
--
-- Lines:  P <page>                         a page was shown
--         E <path> <class> <x> <y> <w> <h> <vis> <label>   one element (main-window client px)
--         C <path> <fired>                 the callbacks one click fired (path:NAME,...)
--         W <text>                         a callback error or runtime warning
local iup = require("iup")
local ffi = require("ffi")

-- Run this script's checkout, whichever build runs it: an IUP exe built from another
-- checkout would otherwise load that checkout's Lua (its lua/ copy and embedded modules).
do
	local here = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
	local root = here:match("^(.*)/scripts/[^/]+$")
	if root and root ~= "" then
		LUNAR_SOURCE_DIR = root
		-- Ahead of the path searcher: main.lua puts the exe's own lua/ first on the path.
		local mine = root .. "/src/lua/?.lua;" .. root .. "/src/lua/?/init.lua"
		table.insert(package.loaders, 2, function(name)
			local file = package.searchpath(name, mine)
			if not file then return nil end
			return assert(loadfile(file))
		end)
		for name in pairs(package.preload) do
			local file = root .. "/src/lua/" .. name:gsub("%.", "/") .. ".lua"
			local f = io.open(file, "r")
			if f then f:close(); local path = root .. "/src/lua/" .. name:gsub("%.", "/") .. ".lua"; package.preload[name] = function(...) return assert(loadfile(path))(...) end end -- kept, so preload-driven discovery (themes) still sees it
		end
	end
end

iup.Message = function(title, text) end

local out_path = ((arg and arg[1]) or ".") .. "/probe-" .. (rawget(iup, "_IMGUI") and "imgui" or "iup") .. ".tsv"
local out = assert(io.open(out_path, "w"))
local function emit(...) out:write(table.concat({ ... }, "\t"), "\n"); out:flush() end

local IMGUI = rawget(iup, "_IMGUI") == true

ffi.cdef[[
typedef struct { long x, y; } PRB_POINT;
int ClientToScreen(void*, PRB_POINT*);
int ScreenToClient(void*, PRB_POINT*);
void* RealChildWindowFromPoint(void*, PRB_POINT);
void* ChildWindowFromPointEx(void*, PRB_POINT, unsigned);
int PostMessageA(void*, unsigned, uintptr_t, intptr_t);
int ShowWindow(void*, int);
int MoveWindow(void*, int, int, int, int, int);
]]
local user32 = ffi.load("user32")

if IMGUI then
	local Runtime = require("core.imgui.Runtime")
	local real = Runtime.warn
	Runtime.warn = function(msg) emit("W", (tostring(msg):gsub("[\r\n\t]+", " | "))); pcall(real, msg) end
	require("core.imgui.Element").hooks.error = function(el, name, err)
		emit("W", name .. ": " .. (tostring(err):gsub("[\r\n\t]+", " | ")))
	end
end

local CLICK_CBS = { "ACTION", "FLAT_ACTION", "BUTTON_CB", "FLAT_BUTTON_CB", "VALUECHANGED_CB",
	"TABCHANGE_CB", "TABCHANGEPOS_CB", "DROPSHOW_CB", "CLICK_CB", "DBLCLICK_CB", "TABCLOSE_CB",
	"FLAT_SELECTION_CB", "SELECTION_CB", "MOUSECLICK_CB", "EXTRABUTTON_CB" }

local STYLE_ATTRS = { "BGCOLOR", "FGCOLOR", "HLCOLOR", "PSCOLOR", "TEXTHLCOLOR", "TEXTPSCOLOR",
	"BORDERCOLOR", "BORDERWIDTH", "CORNERRADIUS", "ITEMRADIUS", "GRADIENTCOLOR", "FONT", "PADDING",
	"MARGIN", "GAP", "SHOWLINES", "TABSACTIVELINE", "TABSSELCOLOR", "TABSBACKCOLOR", "TABSFORECOLOR",
	"TABSHIGHCOLOR", "TABSPADDING", "TABSLINECOLOR", "FORECOLOR", "SB_CORNERRADIUS", "SCROLLBARSIZE",
	"ITEMMARKERCOLOR", "FOCUSFEEDBACK", "TABTYPE", "SHOWTABS" }

local function class(h) return iup.GetClassName(h) end

local function children(h)
	local list, i = {}, 0
	local c = iup.GetChild(h, 0)
	while c do
		list[#list + 1] = c
		i = i + 1
		c = iup.GetChild(h, i)
	end
	return list
end

local function main_hwnd(dlg)
	if IMGUI then
		return ffi.cast("void*", ffi.cast("uintptr_t", tonumber(require("core.imgui.Runtime").backend().window("hwnd"))))
	end
	local IupFFI = require("core.classes.IupFFI")
	return ffi.cast("void*", IupFFI.getptr(IupFFI.ptr(dlg), "HWND"))
end

local function visible(h)
	if IMGUI then return require("core.imgui.Runtime").isVisible(h) end
	return iup.GetAttribute(h, "VISIBLE") == "YES"
end

local origin = { 0, 0 }
local function rect(h)
	local sp = iup.GetAttribute(h, "SCREENPOSITION")
	local sz = iup.GetAttribute(h, "RASTERSIZE") or iup.GetAttribute(h, "CURRENTSIZE")
	local x, y = (sp or ""):match("^(-?%d+),(-?%d+)")
	local w, ht = (sz or ""):match("^(%d+)x(%d+)")
	if not (x and w) then return nil end
	return tonumber(x) - origin[1], tonumber(y) - origin[2], tonumber(w), tonumber(ht)
end

local function label(h)
	for _, a in ipairs({ "TITLE", "TIP", "NAME", "IMAGE", "THEMEROLE" }) do
		local v = iup.GetAttribute(h, a)
		if v and v ~= "" then return a .. "=" .. v:gsub("[\r\n\t]", " "):sub(1, 40) end
	end
	return ""
end

-- Every element under h, with its path of class[index] steps.
local function walk(h, path, list)
	list[#list + 1] = { h = h, path = path }
	for i, c in ipairs(children(h)) do
		walk(c, path .. "/" .. class(c) .. "[" .. (i - 1) .. "]", list)
	end
	return list
end

-- Replace every click callback in the tree with a recorder; keep the originals to restore.
-- LUNAR_PROBE_LIVE=1: run each click's real callbacks and report what goes wrong (a Lua
-- error, a dialog or popup it opens), then close what it opened. Anything that would
-- block the run (message boxes, native file dialogs, opening a browser) is answered
-- with "cancel".
local LIVE = os.getenv("LUNAR_PROBE_LIVE") == "1"
local errors = {}
if LIVE then
	iup.Alarm = function() return 2 end
	iup.GetText = function() return nil end
	iup.GetParam = function() return false end
	iup.ListDialog = function() return -1 end
	pcall(function()
		local desktop = require("core.lib.desktop")
		for _, k in ipairs({ "open", "openUrl", "reveal", "openFolder" }) do
			if desktop[k] then desktop[k] = function() return true end end
		end
	end)
	if IMGUI then
		local B = require("core.imgui.Runtime").backend
		local real_init = require("core.imgui.Runtime").init
		require("core.imgui.Runtime").init = function(backend, ...)
			if backend then
				backend.file_dialog = function() return nil end
				backend.message_box = function() return 2 end
			end
			return real_init(backend, ...)
		end
		local _ = B
	end
end

local fired = {}
local saved = {}
local function stub(list)
	for _, e in ipairs(list) do
		for _, name in ipairs(CLICK_CBS) do
			local lname = name:lower()
			local ok, f = pcall(function() return e.h[lname] end)
			if ok and type(f) == "function" then
				saved[#saved + 1] = { e.h, lname, f }
				e.h[lname] = function(...)
					fired[#fired + 1] = e.path .. ":" .. name
					if LIVE then
						local results = { pcall(f, ...) }
						if not results[1] then
							errors[#errors + 1] = name .. ": " .. (tostring(results[2]):gsub("[\r\n\t]+", " | "))
							return iup.DEFAULT
						end
						return unpack(results, 2)
					end
					return iup.DEFAULT
				end
				e.cb = e.cb or {}
				e.cb[#e.cb + 1] = name
			end
		end
	end
end
local function unstub()
	for i = #saved, 1, -1 do local s = saved[i]; s[1][s[2]] = s[3] end
	saved = {}
end

-- Pages: every leaf of the page tab strips (as ui_capture.lua finds them).
local function leaves(strip, path, acc)
	for i, page in ipairs(children(strip)) do
		local step = {}
		for _, s in ipairs(path) do step[#step + 1] = s end
		step[#step + 1] = { strip = strip, pos = i - 1 }
		if class(page) == "flattabs" then leaves(page, step, acc)
		else acc[#acc + 1] = { path = step, title = iup.GetAttribute(strip, "TABTITLE" .. (i - 1)) or ("tab" .. i) } end
	end
	return acc
end
local function find_strip(h)
	local role = iup.GetAttribute(h, "THEMEROLE")
	if role == "titlebar_tabs" or role == "tool_rail" then return nil end
	if class(h) == "flattabs" then return h end
	for _, c in ipairs(children(h)) do
		local f = find_strip(c)
		if f then return f end
	end
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
		if d and iup.GetAttribute(d, "VISIBLE") == "YES" and find_strip(d) then return d end
	end
end

local function lparam(x, y) return bit.bor(bit.band(x, 0xFFFF), bit.lshift(bit.band(y, 0xFFFF), 16)) end

-- Post a real click at main-window client point (x, y) to whichever window is there.
local function click(hwnd, x, y)
	local target, px, py = hwnd, x, y
	if not IMGUI then
		local pt = ffi.new("PRB_POINT", x, y)
		while true do
			local child = user32.ChildWindowFromPointEx(target, pt, 1 + 4) -- skip invisible, transparent
			if child == nil or child == target then break end
			local s = ffi.new("PRB_POINT", pt.x, pt.y)
			user32.ClientToScreen(target, s)
			user32.ScreenToClient(child, s)
			target, pt = child, s
		end
		px, py = pt.x, pt.y
	end
	user32.PostMessageA(target, 0x0200, 0, lparam(px, py)) -- WM_MOUSEMOVE
	user32.PostMessageA(target, 0x0201, 1, lparam(px, py)) -- WM_LBUTTONDOWN
	user32.PostMessageA(target, 0x0202, 0, lparam(px, py)) -- WM_LBUTTONUP
end

local real_mainloop = iup.MainLoop
iup.MainLoop = function()
	local dlg, hwnd, pages
	local page_i, queue, qi, phase = 0, nil, 1, "boot"
	local ticks = 0
	local function show(page)
		for _, s in ipairs(page.path) do iup.SetAttribute(s.strip, "VALUEPOS", tostring(s.pos)) end
		local shell = rawget(_G, "LUNAR_DEV_SHELL")
		if shell and shell.sync_title_bar then pcall(shell.sync_title_bar) end
		if shell and shell.tab_changed then pcall(shell.tab_changed) end
		iup.Refresh(dlg)
	end
	local t = iup.timer({ time = 120 })
	function t:action_cb()
		local ok, err = pcall(function()
			ticks = ticks + 1
			if phase == "boot" then
				if ticks < 25 then return end
				dlg = main_dialog()
				if not dlg then return end
				hwnd = main_hwnd(dlg)
				if LIVE and IMGUI then
					-- native modal dialogs would block the run on a desktop nobody sees
					local B = require("core.imgui.Runtime").backend()
					B.file_dialog = function() return nil end
					B.message_box = function() return 2 end
				end
				if IMGUI then
					local B = require("core.imgui.Runtime").backend()
					B.window("restore"); B.window("pos", 0, 0); B.window("size", 1400, 900)
				else
					user32.ShowWindow(hwnd, 9); user32.MoveWindow(hwnd, 0, 0, 1400, 900, 1)
				end
				pages = leaves(find_strip(dlg), {}, {})
				phase = "next"
				return
			end
			if phase == "next" then
				page_i = page_i + 1
				local page = pages[page_i]
				if not page then
					phase = "done"
					t.run = "NO"
					out:close()
					iup.ExitLoop()
					return
				end
				show(page)
				phase = "settle"
				ticks = 0
				return
			end
			if phase == "settle" then
				if ticks < 6 then return end
				local page = pages[page_i]
				local pt = ffi.new("PRB_POINT", 0, 0)
				user32.ClientToScreen(hwnd, pt)
				origin[1], origin[2] = pt.x, pt.y
				emit("P", page.title)
				local list = walk(dlg, class(dlg), {})
				stub(list)
				queue = {}
				for _, e in ipairs(list) do
					local x, y, w, h = rect(e.h)
					local vis = visible(e.h)
					emit("E", e.path, class(e.h), x or "", y or "", w or "", h or "", vis and "1" or "0", label(e.h),
						e.cb and table.concat(e.cb, ",") or "")
					-- Style attributes as each build resolves them, for ui_probe_diff's attribute report.
					local av = {}
					for _, k in ipairs(STYLE_ATTRS) do
						local ok, v = pcall(iup.GetAttribute, e.h, k)
						if ok and v ~= nil then av[#av + 1] = k .. "=" .. tostring(v) end
					end
					emit("A", e.path, table.concat(av, ";"))
					-- A disabled control takes no real clicks (a posted one would still reach its window).
					local active = iup.GetAttribute(e.h, "ACTIVE") ~= "NO"
					if vis and active and e.cb and x and w > 2 and h > 2 and x + w / 2 > 0 and y + h / 2 > 0 and x + w / 2 < 1400 and y + h / 2 < 900 then
						queue[#queue + 1] = { e = e, x = math.floor(x + w / 2), y = math.floor(y + h / 2) }
					end
				end
				qi = 1
				phase = "click"
				return
			end
			if phase == "click" then
				local q = queue[qi]
				if not q then
					unstub()
					phase = "next"
					return
				end
				fired, errors = {}, {}
				if LIVE and IMGUI then
					local R = require("core.imgui.Runtime")
					q.dialogs, q.overlays = #R.dialogs(), #R.overlays()
				end
				click(hwnd, q.x, q.y)
				phase = "collect"
				ticks = 0
				return
			end
			if phase == "collect" then
				local q = queue[qi]
				if LIVE and ticks < 4 then return end -- a callback's own timers and frames
				emit("C", q.e.path, table.concat(fired, ","))
				for _, e in ipairs(errors) do emit("X", q.e.path, e) end
				if LIVE and IMGUI then
					local R = require("core.imgui.Runtime")
					local ds, os_ = R.dialogs(), R.overlays()
					if #ds > q.dialogs or #os_ > q.overlays then
						local titles = {}
						for i = q.dialogs + 1, #ds do titles[#titles + 1] = tostring(iup.GetAttribute(ds[i], "TITLE")) end
						emit("N", q.e.path, string.format("dialogs +%d overlays +%d %s", #ds - q.dialogs, #os_ - q.overlays, table.concat(titles, "; ")))
					end
					for i = #os_, q.overlays + 1, -1 do pcall(function() os_[i]:close() end) end
					for i = #ds, q.dialogs + 1, -1 do pcall(iup.Hide, ds[i]) end
				end
				qi = qi + 1
				-- The click may have changed a tab or a toggle: show the page again.
				show(pages[page_i])
				phase = "click"
			end
		end)
		if not ok then emit("W", "probe: " .. tostring(err)) end
		if phase == "done" then return iup.CLOSE end
		return iup.DEFAULT
	end
	t.run = "YES"
	return real_mainloop()
end

local ok, err = pcall(dofile, (LUNAR_SOURCE_DIR or ".") .. "/src/lua/core/main.lua")
if not ok then emit("W", "main.lua: " .. tostring(err)); out:close(); os.exit(1) end
os.exit(0)
