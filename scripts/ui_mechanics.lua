-- scripts/ui_mechanics.lua -- the title bar and tab strip mechanics through real window messages,
-- on either build: the sidebar, terminal and theme buttons each toggle once, and a dragged tab
-- reorders. Lunar scripts/ui_mechanics.lua <out_dir>  (writes mechanics-<build>.txt)
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
local out = assert(io.open(((arg and arg[1]) or ".") .. "/mechanics-" .. (IMGUI and "imgui" or "iup") .. ".txt", "w"))
local function say(...) out:write(table.concat({ ... }, " "), "\n"); out:flush() end
if IMGUI then
	local R = require("core.imgui.Runtime")
	local rw = R.warn
	R.warn = function(m) say("WARN", (tostring(m):gsub("\n", " | "):sub(1, 900))); pcall(rw, m) end
	require("core.imgui.Element").hooks.error = function(el, name, e) say("CBERR", name, (tostring(e):gsub("\n", " | "):sub(1, 900))) end
end
local real_message = iup.Message
iup.Message = function(t, m) say("MESSAGE", tostring(t), (tostring(m):gsub("\n", " | "))) end
ffi.cdef[[
typedef struct { long x, y; } MC_POINT;
int ClientToScreen(void*, MC_POINT*);
int ScreenToClient(void*, MC_POINT*);
void* ChildWindowFromPointEx(void*, MC_POINT, unsigned);
int PostMessageA(void*, unsigned, uintptr_t, intptr_t);
int MoveWindow(void*, int, int, int, int, int);
int ShowWindow(void*, int);
]]
local user32 = ffi.load("user32")
local function hwnd_of(dlg)
	if IMGUI then return ffi.cast("void*", ffi.cast("uintptr_t", tonumber(require("core.imgui.Runtime").backend().window("hwnd")))) end
	local IupFFI = require("core.classes.IupFFI")
	return ffi.cast("void*", IupFFI.getptr(IupFFI.ptr(dlg), "HWND"))
end
local function lp(x, y) return bit.bor(bit.band(x, 0xFFFF), bit.lshift(bit.band(y, 0xFFFF), 16)) end
local main_hwnd
-- post to whichever window is at main-client (x, y), in its own coordinates
local function target(x, y)
	local t, pt = main_hwnd, ffi.new("MC_POINT", x, y)
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
local function post(kind, x, y)
	local t, px, py = target(x, y)
	local msg = ({ move = 0x0200, down = 0x0201, up = 0x0202 })[kind]
	user32.PostMessageA(t, msg, (kind == "up") and 0 or ((kind == "down" or kind == "drag") and 1 or 0), lp(px, py))
end
local function rect(h)
	local o = ffi.new("MC_POINT", 0, 0); user32.ClientToScreen(main_hwnd, o)
	local x, y = tostring(iup.GetAttribute(h, "SCREENPOSITION")):match("^(-?%d+),(-?%d+)")
	local w, hh = tostring(iup.GetAttribute(h, "RASTERSIZE")):match("^(%d+)x(%d+)")
	return tonumber(x) - o.x, tonumber(y) - o.y, tonumber(w), tonumber(hh)
end
local function find(h, pred)
	if pred(h) then return h end
	local i, c = 0, iup.GetChild(h, 0)
	while c do
		local f = find(c, pred); if f then return f end
		i = i + 1; c = iup.GetChild(h, i)
	end
end
local real = iup.MainLoop
iup.MainLoop = function()
	local step, dlg, shell, images = 0, nil, nil, {}
	local mode_btn, bars_btn, term_btn, tabs
	local t = iup.timer({ time = 150 })
	function t:action_cb()
		step = step + 1
		local ok, err = pcall(function()
			if step == 30 then
				shell = LUNAR_DEV_SHELL
				dlg = iup.GetDialog(shell.groups():rootStrip())
				main_hwnd = hwnd_of(dlg)
				if IMGUI then local B = require("core.imgui.Runtime").backend(); B.window("restore"); B.window("pos", 0, 0); B.window("size", 1400, 900)
				else user32.ShowWindow(main_hwnd, 9); user32.MoveWindow(main_hwnd, 0, 0, 1400, 900, 1) end
			elseif step == 36 then
				local function tip(s) return function(h) return iup.GetClassName(h) == "flatbutton" and tostring(iup.GetAttribute(h, "TIP") or ""):find(s, 1, true) end end
				mode_btn = find(dlg, tip("theme")) or find(dlg, tip("mode"))
				bars_btn = find(dlg, tip("sidebar and status bar"))
				term_btn = find(dlg, tip("terminal"))
				-- a page strip on screen with at least two tabs (not the title bar's mirror)
				local function vis(h) if IMGUI then return require("core.imgui.Runtime").isVisible(h) end return iup.GetAttribute(h, "VISIBLE") == "YES" end
				tabs = find(dlg, function(h)
					return iup.GetClassName(h) == "flattabs" and iup.GetAttribute(h, "THEMEROLE") ~= "titlebar_tabs"
						and (tonumber(iup.GetAttribute(h, "COUNT")) or 0) >= 2 and vis(h)
						and tostring(iup.GetAttribute(h, "SHOWTABS")) ~= "NO"
				end)
				say("found mode", tostring(mode_btn ~= nil), "bars", tostring(bars_btn ~= nil), "term", tostring(term_btn ~= nil), "tabs", tostring(tabs ~= nil))
				if IMGUI then
					local B = require("core.imgui.Runtime").backend()
					local fb = B.frame_begin
					B.frame_begin = function(...)
						local input = fb(...)
						if input.events and #input.events > 0 then
							local list = {}
							for _, e in ipairs(input.events) do list[#list + 1] = e.type .. (e.button and e.button > 0 and e.button or "") .. "@" .. math.floor(e.x) .. "," .. math.floor(e.y) end
							say("EVENTS", table.concat(list, " "))
						end
						return input
					end
				end
				for name, b in pairs({ mode = mode_btn, bars = bars_btn, term = term_btn }) do
					local f = b.flat_action
					say("rect", name, rect(b))
					b.flat_action = function(...)
						say("FLAT_ACTION", name)
						local r = { pcall(f, ...) }
						if not r[1] then say("ACTIONERR", name, tostring(r[2])) end
						return r[2]
					end
				end
				say("before: bars", tostring(shell.view_layout:barsVisible()), "terminal", tostring(shell.view_layout:terminalVisible()))
				local x, y, w, h = rect(bars_btn)
				post("move", x + math.floor(w / 2), y + math.floor(h / 2)); post("down", x + math.floor(w / 2), y + math.floor(h / 2)); post("up", x + math.floor(w / 2), y + math.floor(h / 2))
			elseif step == 40 then
				say("after bars click: bars", tostring(shell.view_layout:barsVisible()))
				local x, y, w, h = rect(term_btn)
				post("move", x + math.floor(w / 2), y + math.floor(h / 2)); post("down", x + math.floor(w / 2), y + math.floor(h / 2)); post("up", x + math.floor(w / 2), y + math.floor(h / 2))
			elseif step == 44 then
				say("after terminal click: terminal", tostring(shell.view_layout:terminalVisible()))
				-- the mode button: count the images it shows while the icon turns
				local x, y, w, h = rect(mode_btn)
				say("mode tip before:", tostring(iup.GetAttribute(mode_btn, "TIP")))
				post("move", x + math.floor(w / 2), y + math.floor(h / 2)); post("down", x + math.floor(w / 2), y + math.floor(h / 2)); post("up", x + math.floor(w / 2), y + math.floor(h / 2))
			elseif step > 44 and step <= 60 then
				local img = tostring(iup.GetAttribute(mode_btn, "IMAGE"))
				if images[#images] ~= img then images[#images + 1] = img end
			elseif step == 61 then
				say("mode tip after:", tostring(iup.GetAttribute(mode_btn, "TIP")), "distinct images during the turn:", #images)
				local tm = shell.host and shell.host._theme_mgr
				-- tab drag: the second title-bar tab onto the first one's place
				local count = tonumber(iup.GetAttribute(tabs, "COUNT")) or 0
				local before = {}
				for i = 0, count - 1 do before[#before + 1] = tostring(iup.GetAttribute(tabs, "TABTITLE" .. i)) end
				say("titlebar tabs before:", table.concat(before, " | "))
				local probe = {}
				for x = 0, 300, 20 do probe[#probe + 1] = x .. ":" .. tostring(iup.ConvertXYToPos(tabs, x, 14)) end
				say("xy2pos", table.concat(probe, " "))
				local order = require("core.classes.TabOrder")
				say("tab_order", type(order))
				if type(order) == "table" then
					for _, m in ipairs({ "_resolveDrop", "_scheduleDrop", "_applyDrop", "_scheduleSnap" }) do
						local f = order[m]
						if type(f) == "function" then
							order[m] = function(self_, ...)
								local r = { pcall(f, self_, ...) }
								local d = r[2]
								local desc = type(d) == "table" and ("{kind=" .. tostring(d.kind) .. " pos=" .. tostring(d.pos) .. " index=" .. tostring(d.index) .. "}") or tostring(d)
								say("TO", m, r[1] and "ok" or "ERROR", desc)
								if not r[1] then error(r[2], 0) end
								return unpack(r, 2)
							end
						end
					end
				end
				for _, name in ipairs({ "flat_button_cb", "flat_motion_cb" }) do
					local f = tabs[name]
					say("has", name, type(f))
					if type(f) == "function" then
						tabs[name] = function(self_, ...)
							local args = { ... }
							for i = 1, #args do args[i] = tostring(args[i]) end
							local r = { pcall(f, self_, ...) }
							say("CB", name, table.concat(args, ","), "->", tostring(r[2]), r[1] and "" or "ERROR")
							return r[2]
						end
					end
				end
				local x, y, w, h = rect(tabs)
				shell._drag = { x = x, y = y + 14, w = w }
				post("move", x + 150, y + 14); post("down", x + 150, y + 14)
			elseif step >= 62 and step <= 70 then
				local d = shell._drag
				post("move", d.x + 150 - (step - 61) * 16, d.y)
			elseif step == 71 then
				local d = shell._drag
				post("up", d.x + 10, d.y)
			elseif step == 76 then
				local count = tonumber(iup.GetAttribute(tabs, "COUNT")) or 0
				local after = {}
				for i = 0, count - 1 do after[#after + 1] = tostring(iup.GetAttribute(tabs, "TABTITLE" .. i)) end
				say("titlebar tabs after drag:", table.concat(after, " | "))
				out:close()
				os.exit(0)
			end
		end)
		if not ok then say("ERR", tostring(err)) end
		return iup.DEFAULT
	end
	t.run = "YES"
	return real()
end
local here = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
local root = here:match("^(.*)/scripts/[^/]+$") or LUNAR_SOURCE_DIR
dofile(root .. "/src/lua/core/main.lua")
os.exit(0)
