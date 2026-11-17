-- scripts/ui_capture.lua — start Lunar normally, walk every tab, and save a PNG-ready
-- bitmap of the main window for each one. Used for before/after design review.
--
-- Run (Windows dev build):
--   Lunar scripts/ui_capture.lua <out_dir> [prefix]
-- Point %APPDATA% at a scratch folder first so the run leaves real settings alone.
-- Output is 32-bit BMP (<out_dir>/<prefix>-NN-<tab>.bmp); convert with any tool.
-- A page with a fixture in scripts/ui_fixtures.lua gets a second shot, <tab>-data.
-- Set LUNAR_CAPTURE_SIZE=680x900 to walk the pages at that window size, not maximized.

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
			if f then f:close(); local path = root .. "/src/lua/" .. name:gsub("%.", "/") .. ".lua"; package.preload[name] = function(...) return assert(loadfile(path))(...) end end -- kept, so preload-driven discovery (themes) still sees it
		end
	end
end

-- The executable boots the ImGui runtime before it invokes this script. Reload
-- paint code from this checkout before any widgets exist, just as we reload UI
-- modules above; otherwise draw-context/runtime edits silently use embedded Lua.
if rawget(iup, "_IMGUI") then
	package.loaded["core.imgui.Draw"] = nil
	package.loaded["core.imgui.Runtime"] = nil
	-- Draw secondary dialogs as panels in this capture-only runtime. Their
	-- rendered pixels then belong to the full app buffer (no desktop reads).
	local backend = require("core.imgui.backend.Native")
	backend.dialog_windows = false
	require("core.imgui.Runtime").init(backend)
end

-- Nobody is there to dismiss a dialog, and one would stop the run with nothing to show for it.
iup.Message = function(title, text)
	io.stderr:write("ui_capture: ", tostring(title), ": ", tostring(text), string.char(10))
end

local out_dir = (arg and arg[1]) or "."
local prefix = (arg and arg[2]) or "shot"

ffi.cdef[[
typedef struct { long left, top, right, bottom; } CAP_RECT;
typedef struct { uint32_t biSize; long biWidth, biHeight; uint16_t biPlanes, biBitCount;
  uint32_t biCompression, biSizeImage; long biXPelsPerMeter, biYPelsPerMeter;
  uint32_t biClrUsed, biClrImportant; } CAP_BMIH;
int GetClientRect(void*, CAP_RECT*);
int ClientToScreen(void*, CAP_RECT*);
int GetWindowRect(void*, CAP_RECT*);
int BitBlt(void*, int, int, int, int, void*, int, int, unsigned);
void* GetDC(void*);
int ReleaseDC(void*, void*);
int PrintWindow(void*, void*, unsigned);
int ShowWindow(void*, int);
int MoveWindow(void*, int, int, int, int, int);
void* CreateCompatibleDC(void*);
void* CreateCompatibleBitmap(void*, int, int);
void* SelectObject(void*, void*);
int GetDIBits(void*, void*, unsigned, unsigned, void*, CAP_BMIH*, unsigned);
int DeleteObject(void*);
int DeleteDC(void*);
long DwmGetWindowAttribute(void*, unsigned, void*, unsigned);
int PostMessageW(void*, unsigned, uintptr_t, intptr_t);
]]
local user32, gdi32, dwmapi = ffi.load("user32"), ffi.load("gdi32"), ffi.load("dwmapi")

-- from_screen copies what is really on screen, title bar and menu included: a popup,
-- and an edit control's cue banner, only paint for WM_PAINT, which PrintWindow does not
-- send. Set LUNAR_CAPTURE_CLIENT=1 for the old client-only shot of a covered window.
-- On the ImGui host there is no HWND per dialog and the GL surface does not answer
-- PrintWindow: the backend reads its own back buffer instead (the whole window, or one
-- dialog's panel), which also means the shot never touches the screen.
local IMGUI = rawget(iup, "_IMGUI") == true
local function window_of(dlg)
	if IMGUI then return dlg end
	local IupFFI = require("core.classes.IupFFI")
	return ffi.cast("void*", IupFFI.getptr(IupFFI.ptr(dlg), "HWND"))
end

local save_bmp_native
local function save_bmp(target, path, from_screen)
	if not IMGUI then return save_bmp_native(target, path, from_screen) end
	local Runtime = require("core.imgui.Runtime")
	local B = Runtime.backend()
	local Element = require("core.imgui.Element")
	local st = Element.state(target)
	-- Native popovers may extend beyond the parent window. In panel capture
	-- mode keep the complete floating surface inside the app buffer.
	local main = Runtime.mainDialog()
	local mst = main and Element.state(main)
	if mst then
		local inset = require("core.lib.CarbonLayout").px(3)
		for _, dialog in ipairs(Runtime.dialogs()) do
			local ds = Element.state(dialog)
			if dialog ~= main and ds then
				ds.data.ox = math.max(inset, math.min(ds.data.ox or inset, mst.w - ds.w - inset))
				ds.data.oy = math.max(inset, math.min(ds.data.oy or inset, mst.h - ds.h - inset))
			end
		end
	end
	-- The backend reads the back buffer at the end of the next frame, which also shows
	-- the state after the step that asked for the shot.
	if target == Runtime.mainDialog() or not st then B.screenshot(path)
	elseif st.data.win then
		-- a dialog in its own window (secondary dialogs are native windows): its back buffer
		B.screenshot(path, 0, 0, 0, 0, st.data.win)
	else
		local top = st.data.chrome and st.data.chrome.top or 0
		B.screenshot(path, st.data.ox or 0, (st.data.oy or 0) - top, st.w, st.h + top)
	end
	Runtime.frame()
end

function save_bmp_native(hwnd, path, from_screen)
	local rc = ffi.new("CAP_RECT")
	if from_screen then
		-- The visible frame: GetWindowRect also counts the invisible resize border.
		if dwmapi.DwmGetWindowAttribute(hwnd, 9, rc, ffi.sizeof(rc)) ~= 0 then -- EXTENDED_FRAME_BOUNDS
			user32.GetWindowRect(hwnd, rc)
		end
	else
		user32.GetClientRect(hwnd, rc)
	end
	local w, h = rc.right - rc.left, rc.bottom - rc.top
	local dc_owner = hwnd
	if from_screen then dc_owner = nil end -- nil is the whole screen
	local screen = user32.GetDC(dc_owner)
	local mem = gdi32.CreateCompatibleDC(screen)
	local bmp = gdi32.CreateCompatibleBitmap(screen, w, h)
	local old = gdi32.SelectObject(mem, bmp)
	if from_screen then
		gdi32.BitBlt(mem, 0, 0, w, h, screen, rc.left, rc.top, 0x00CC0020) -- SRCCOPY
	else
		-- PW_CLIENTONLY trims a standard caption off the top, which this window may not have,
		-- so take the whole window and cut the client area out of it.
		local win, origin = ffi.new("CAP_RECT"), ffi.new("CAP_RECT")
		user32.GetWindowRect(hwnd, win)
		user32.ClientToScreen(hwnd, origin)
		local whole_w, whole_h = win.right - win.left, win.bottom - win.top
		local whole_dc = gdi32.CreateCompatibleDC(screen)
		local whole = gdi32.CreateCompatibleBitmap(screen, whole_w, whole_h)
		local previous = gdi32.SelectObject(whole_dc, whole)
		user32.PrintWindow(hwnd, whole_dc, 2) -- PW_RENDERFULLCONTENT
		gdi32.BitBlt(mem, 0, 0, w, h, whole_dc, origin.left - win.left, origin.top - win.top, 0x00CC0020)
		gdi32.SelectObject(whole_dc, previous)
		gdi32.DeleteObject(whole)
		gdi32.DeleteDC(whole_dc)
	end
	gdi32.SelectObject(mem, old)
	local bi = ffi.new("CAP_BMIH")
	bi.biSize, bi.biWidth, bi.biHeight, bi.biPlanes, bi.biBitCount = ffi.sizeof(bi), w, h, 1, 32
	local bytes = w * h * 4
	local px = ffi.new("uint8_t[?]", bytes)
	gdi32.GetDIBits(mem, bmp, 0, h, px, bi, 0)
	gdi32.DeleteObject(bmp)
	gdi32.DeleteDC(mem)
	user32.ReleaseDC(dc_owner, screen)
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

local whole_window = os.getenv("LUNAR_CAPTURE_CLIENT") ~= "1"

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
	local role = iup.GetAttribute(h, "THEMEROLE")
	if role == "titlebar_tabs" or role == "tool_rail" then return nil end
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
local SAMPLE_SETS = {
	{ "Boot order regression", "Memory training", "PCIe link width", "Secure boot keys",
	  "Fan curve validation", "NVMe hot plug", "Power cap limits", "TPM attestation",
	  "Thermal throttle", "UEFI variable store", "Watchdog recovery", "BMC failover",
	  "DIMM population", "USB enumeration", "Option ROM scan", "SMBIOS tables",
	  "ACPI table checks", "Secure erase", "Sensor calibration", "Redfish conformance" },
	{ "AmiBcp", "BiosUpdate", "CpuFreq", "CpldTool", "DumpSmbios", "EfiShell", "FwFlash",
	  "GpioMap", "HpSetup", "IpmiUtil", "LogCollect", "MemTest", "NvramTool", "PcieScan",
	  "RomBuilder", "SmmDebug", "TpmTool", "UefiPatch", "VpdEdit", "WdtProbe" },
	{ "Boot order regression", "Fan curve validation", "TPM attestation", "AmiBcp", "RomBuilder" },
}
local sample_set = 0

-- Screenshots leave this machine, and org packs prefill internal hosts and addresses.
local function scrubbed(value)
	return (value:gsub([[\[%w%.%-_]+[%w%.%-_\%$]*]], [[\server\share]])
		:gsub("https?://[%w%.%-_:]+", "https://backend.example:8000")
		:gsub("%d+%.%d+%.%d+%.%d+", "192.0.2.10"))
end

local function fill_lists(h)
	local attr = class(h) == "text" and "VALUE"
		or ((class(h) == "label" or class(h) == "flatlabel" or class(h) == "flatbutton") and "TITLE")
	local value = attr and iup.GetAttribute(h, attr)
	if type(value) == "string" and value ~= "" and scrubbed(value) ~= value then
		iup.SetAttribute(h, attr, scrubbed(value))
	end
	if class(h) == "flatlist" and (tonumber(iup.GetAttribute(h, "COUNT")) or 0) == 0
		and iup.GetAttribute(h, "THEMEROLE") ~= "palette_list" then
		sample_set = sample_set % #SAMPLE_SETS + 1
		for i, row in ipairs(SAMPLE_SETS[sample_set]) do iup.SetAttribute(h, tostring(i), row) end
	end
	local i, child = 0, iup.GetChild(h, 0)
	while child do
		fill_lists(child)
		i = i + 1
		child = iup.GetChild(h, i)
	end
end

-- Work for the Activity shots: two real jobs (a slow tool that can be cancelled, and one
-- that fails on the spot) and the kinds of entry the org packs make through ctx:activity.
local activity_scene = {}

local function owner_named(host, name)
	for owner, manifest in pairs(host._manifest_by_owner) do
		if manifest.name == name then return owner end
	end
end

function activity_scene.start(shell)
	local host = shell.host
	-- A batch file, because the JSON's quotes wouldn't survive a command line.
	local tool = out_dir .. "/activity-job.cmd"
	local file = assert(io.open(tool, "w"))
	file:write("@echo {\"v\":1,\"type\":\"progress\",\"done\":46,\"total\":100,\"message\":\"Uploading 675.30\"}\n")
	file:write("@ping -n 60 127.0.0.1 >nul\n")
	file:close()
	activity_scene.job = assert(host:startJob({
		argv = { "cmd", "/c", (tool:gsub("/", "\\")) },
		activity = { title = "Black Duck scan", cancel = true },
	}, owner_named(host, "Black Duck")))
	assert(host:startJob({
		argv = { "cmd", "/c", "exit 3" }, activity = { title = "Release check" },
	}, owner_named(host, "Black Duck Server") or owner_named(host, "Black Duck")))
	local stop = function() end
	activity_scene.queue = host:activity({ title = "Build Queue", cancel = stop },
		owner_named(host, "Build Queue"))
	activity_scene.queue:progress(3, 12, "Building RomBuilder")
	activity_scene.flash = host:activity({ title = "Firmware flash" }, owner_named(host, "iLO Redfish"))
	activity_scene.flash:progress(55, 100, "ilo6_307.fwpkg")
	host:activity({ title = "Log Parser" }, owner_named(host, "Log Parser"))
		:finish(true, "12 failures across 4 files in 8.2 s")
end

function activity_scene.finish(shell)
	shell.host:activityStore():cancel(shell.host:activityStore():running()[1].id)
	activity_scene.queue:finish(false, "2 of 12 failed")
	activity_scene.flash:finish(true, "Firmware flash finished.")
end

-- The layout next to each shot: one line per visible element, "path class x y w h label",
-- in main-window client pixels, the same on both builds (diff them with
-- scripts/ui_tree_diff.lua).
local function dump_tree(dlg, path)
	local f = io.open(path, "w")
	if not f then return end
	local pt = ffi.new("CAP_RECT")
	local ox, oy = 0, 0
	if IMGUI then
		local Runtime = require("core.imgui.Runtime")
		local x, y = Runtime.backend().window("client_origin")
		ox, oy = x or 0, y or 0
	else
		user32.ClientToScreen(window_of(dlg), pt)
		ox, oy = pt.left, pt.top
	end
	local function vis(h)
		if IMGUI then return require("core.imgui.Runtime").isVisible(h) end
		return iup.GetAttribute(h, "VISIBLE") == "YES"
	end
	-- IUP has no SCREENPOSITION for a box: its POSITION is relative to the nearest
	-- ancestor that has a window, whose screen position is known.
	local function screen_of(h)
		local x, y = tostring(iup.GetAttribute(h, "SCREENPOSITION") or ""):match("^(-?%d+),(-?%d+)")
		if x or IMGUI then return tonumber(x), tonumber(y) end
		local px, py = tostring(iup.GetAttribute(h, "POSITION") or ""):match("^(-?%d+),(-?%d+)")
		local a = iup.GetParent(h)
		while a do
			local ax, ay = tostring(iup.GetAttribute(a, "SCREENPOSITION") or ""):match("^(-?%d+),(-?%d+)")
			if ax and iup.GetClassName(a) ~= "dialog" then return tonumber(ax) + tonumber(px or 0), tonumber(ay) + tonumber(py or 0) end
			if iup.GetClassName(a) == "dialog" then return ox + tonumber(px or 0), oy + tonumber(py or 0) end
			a = iup.GetParent(a)
		end
	end
	local function walk(h, p)
		if vis(h) then
			local sz = iup.GetAttribute(h, "RASTERSIZE")
			local x, y = screen_of(h)
			local w, hh = tostring(sz or ""):match("^(%d+)x(%d+)")
			local label = ""
			for _, a in ipairs({ "TITLE", "TIP", "NAME", "THEMEROLE" }) do
				local v = iup.GetAttribute(h, a)
				if v and v ~= "" then label = tostring(v):gsub("[\r\n\t]", " "):sub(1, 40); break end
			end
			if x and w then
				f:write(table.concat({ p, iup.GetClassName(h), tonumber(x) - ox, tonumber(y) - oy, w, hh, label }, "\t"), "\n")
			end
		end
		local i, c = 0, iup.GetChild(h, 0)
		while c do
			walk(c, p .. "/" .. iup.GetClassName(c) .. "[" .. i .. "]")
			i = i + 1
			c = iup.GetChild(h, i)
		end
	end
	walk(dlg, "dialog")
	f:close()
end

local fixtures = dofile((LUNAR_SOURCE_DIR or ".") .. "/scripts/ui_fixtures.lua")

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
			save_bmp(window_of(dlg),
				string.format("%s/%s-%s.bmp", out_dir, prefix, name), whole_window)
		end
		-- One window's own pixels, whatever is over it: a shared desktop can cover the
		-- status bar, and a screen grab would then show the taskbar instead.
		local function snap_window(window, name)
			save_bmp(window_of(window),
				string.format("%s/%s-%s.bmp", out_dir, prefix, name), false)
		end
		local function snap_overlays(name)
			if not IMGUI then return end
			local R=require("core.imgui.Runtime")
			for i,o in ipairs(R.overlays()) do
				if o.open and o.win then R.backend().screenshot(string.format("%s/%s-%s-%d.bmp",out_dir,prefix,name,i),0,0,0,0,o.win) end
			end
			R.frame()
		end
		if scene == 1 then
			if os.getenv("LUNAR_CAPTURE_NEST") then
				local groups = shell.groups()
				local first = groups:_children(groups:rootStrip())[1]
				iup.SetAttribute(groups:rootStrip(), "VALUEPOS", "0")
				groups:createGroup(first, "Bench setups", "user")
				shell.sync_title_bar()
				snap("89-letter")
			end
			shell.palette:open("")
		elseif scene == 2 then
			local palette_dlg = shell.palette._dialog
			snap("90-palette") -- over the app, so the shot shows how it sits on the page
			snap_window(palette_dlg, "90-palette-window")
			local _ = palette_dlg
			shell.palette:close()
		elseif scene == 3 then
			local groups = shell.groups()
			local pages_now = groups:leaves()
			shell.panes:move(pages_now[3] or pages_now[1], "right")
			if pages_now[4] then shell.panes:move(pages_now[4], "bottom") end
		elseif scene == 5 then -- one tick later: pages recentre after the panes settle
			snap("91-split")
		elseif scene == 6 then
			-- Exercise the actual overflow renderer, rather than the menu search palette.
			if IMGUI then
				local menu = iup.menu({ iup.item({TITLE="Open file...\tCtrl+O"}),
					iup.item({TITLE="Settings\tCtrl+,"}), iup.separator({}),
					iup.item({TITLE="Check for updates"}), iup.item({TITLE="Show activity"}) })
				shell._capture_menu = require("core.imgui.widgets.menu").popupMenu(menu, 300, 64, require("core.imgui.Runtime"))
			else shell.open_menu() end
		elseif scene == 7 then
			snap("92-menu")
			snap_overlays("92-menu-window")
			if IMGUI then for _,o in ipairs(require("core.imgui.Runtime").overlays()) do if o.open then o:close() end end end
			shell.palette:close()
			-- Another window taking focus would dismiss the panel between shots.
			shell.activity._hasFocus = function() return true end
			shell.activity:open()
		elseif scene == 8 then
			snap_window(shell.activity._dialog, "93-activity-empty")
			shell.activity:close()
			activity_scene.start(shell)
		elseif scene == 10 then
			shell.activity:open()
			snap("94-activity-running")
			shell.activity:_move(2) -- onto the Build Queue row, which offers both actions
		elseif scene == 11 then
			snap_window(shell.activity._dialog, "95-activity")
			snap("95-activity-over-app")
			shell.activity:close()
			activity_scene.finish(shell)
		elseif scene == 12 then
			snap_window(dlg, "96-activity-result")
			local toasts=shell.host:toasts()
			local pending={}; for _,rec in ipairs(toasts and toasts._stack or {}) do pending[#pending+1]=rec end
			for _,rec in ipairs(pending) do if rec.alive then toasts:_exitToast(rec) end end
			-- LUNAR_CAPTURE_CODE=path: a real file in the Code tab, against whatever language
			-- server this machine has, through the path a user takes.
			local code_file = os.getenv("LUNAR_CAPTURE_CODE")
			if not (code_file and shell.code) then
				if shell.host.notify then shell.host:notify({ kind = "info", title = "Settings saved", body = "Your appearance preferences are up to date.", timeout = 1500 }) end
				return true
			end
			local opened, why = shell.code:open(code_file, { line = 1 })
			io.stderr:write("ui_capture: open ", tostring(opened), " ", tostring(why), string.char(10))
		elseif scene == 13 and not os.getenv("LUNAR_CAPTURE_CODE") then
			-- The toast is taken at rest: say where the pointer and the keyboard are, so the
			-- shot can be checked against them (a close outline would mean focus or hover).
			if IMGUI then
				local Runtime = require("core.imgui.Runtime")
				local function in_toast(h)
					local toasts = shell.host:toasts()
					for _, rec in ipairs(toasts and toasts._stack or {}) do
						local p = h
						while p do if p == rec.dlg then return true end; p = iup.GetParent(p) end
					end
					return false
				end
				local hovered, focus = Runtime.hovered(), iup.GetFocus()
				local mx, my = Runtime.lastMouse()
				local line = string.format("toast at rest: pointer %s,%s over %s (in toast: %s); focus in toast: %s",
					tostring(mx), tostring(my), hovered and iup.GetClassName(hovered) or "nothing",
					tostring(hovered ~= nil and in_toast(hovered)), tostring(focus ~= nil and in_toast(focus)))
				local f = io.open(string.format("%s/%s-96-toast.state", out_dir, prefix), "w")
				if f then f:write(line, string.char(10)); f:close() end
			end
			snap("96-toast")
			local toasts=shell.host:toasts()
			for i,rec in ipairs(toasts and toasts._stack or {}) do if rec.alive then snap_window(rec.dlg,"96-toast-window-"..i) end end
			snap("97-glass-on")
			require("core.ui.Glass").setEnabled(false)
			iup.Update(dlg)
		elseif scene == 14 and not os.getenv("LUNAR_CAPTURE_CODE") then
			snap("97-glass-off")
			require("core.ui.Glass").setEnabled(true)
		elseif scene == 15 and not os.getenv("LUNAR_CAPTURE_CODE") then
			for _,page in ipairs(leaves(find_strip(dlg),{},{})) do
				if page.title:lower()=="settings" then for _,s in ipairs(page.path) do iup.SetAttribute(s.strip,"VALUEPOS",tostring(s.pos)) end end
			end
			iup.Refresh(dlg)
		elseif scene == 16 and not os.getenv("LUNAR_CAPTURE_CODE") then
			local R,E=require("core.imgui.Runtime"),require("core.imgui.Element")
			local function find(h)
				if class(h)=="dropbutton" and R.isVisible(h) then return h end
				for _,c in ipairs(E.children(h)) do local result=find(c); if result then return result end end
			end
			shell._capture_dropdown=find(dlg)
			if shell._capture_dropdown then
				local list=iup.GetHandle(iup.GetAttribute(shell._capture_dropdown,"DROPCHILD"))
				if list then
					for i,label in ipairs({"Local build logs", "Nightly validation", "Release qualification"}) do iup.SetAttribute(list,tostring(i),label) end
					iup.SetAttribute(list,"4",nil)
					iup.SetAttribute(list,"VISIBLELINES","3")
					iup.SetAttribute(list,"VALUE","1")
				end
				iup.SetAttribute(shell._capture_dropdown,"SHOWDROPDOWN","YES")
			end
		elseif scene == 17 and not os.getenv("LUNAR_CAPTURE_CODE") then
			snap("98-dropdown-over-app")
			snap_overlays("98-dropdown")
			if shell._capture_dropdown then iup.SetAttribute(shell._capture_dropdown,"SHOWDROPDOWN","NO") end
		elseif scene == 18 and not os.getenv("LUNAR_CAPTURE_CODE") then
			local R,E=require("core.imgui.Runtime"),require("core.imgui.Element")
			local widget=shell._capture_dropdown
			if widget then
				iup.SetAttribute(widget,"TIP","Choose the application colour palette")
				iup.SetAttribute(widget,"TIP","Choose a location to scan")
				local st=E.state(widget); local B=R.backend()
				local surface=B.surface
				B.surface=function(id) if id and id~=0 then shell._capture_tip_surface=id end; return surface(id) end
				local begin=B.frame_begin
				shell._capture_restore_input=function() B.frame_begin=begin end
				B.frame_begin=function()
					local input=begin()
					input.events={{type="move",x=st.x+10,y=st.y+10,mods={}}}
					return input
				end
			end
		elseif scene == 21 and not os.getenv("LUNAR_CAPTURE_CODE") then
			local R=require("core.imgui.Runtime")
			snap("99-tooltip-over-app")
			if shell._capture_tip_surface then
				R.backend().screenshot(string.format("%s/%s-99-tooltip.bmp",out_dir,prefix),0,0,0,0,shell._capture_tip_surface)
				R.frame()
			end
			if shell._capture_restore_input then shell._capture_restore_input() end
			if shell.code then assert(shell.code:open(LUNAR_SOURCE_DIR .. "/src/lua/core/ui/Glass.lua", {line=0})) end
		elseif scene == 23 and not os.getenv("LUNAR_CAPTURE_CODE") then
			snap_window(dlg,"100-editor")
			if shell.view_layout and shell.terminal then
				shell.view_layout:toggleTerminal()
			end
		elseif scene == 24 and not os.getenv("LUNAR_CAPTURE_CODE") then
			snap_window(dlg,"100-terminal-fitting")
			if shell.terminal then shell.terminal:execute("help") end
		elseif scene == 25 and not os.getenv("LUNAR_CAPTURE_CODE") then
			snap_window(dlg,"101-terminal")
			return false
		elseif scene == 34 then -- about 20 seconds: a server has to index before it reports
			io.stderr:write("ui_capture: servers ", tostring(shell.code:_serverSummary()), string.char(10))
			snap_window(dlg, "97-code")
			shell.code:showProblems()
		elseif scene == 36 then
			snap_window(dlg, "98-problems")
			local doc = shell.code:_current()
			local say = function(...) io.stderr:write("ui_capture: ", table.concat({ ... }, " "), string.char(10)) end
			shell.code._scene = { doc = doc, say = say }
			local point = doc.view:pointOf(1, 0)
			doc.binder:_hover(tonumber(os.getenv("LUNAR_CAPTURE_HOVER_LINE")) or 7,
				tonumber(os.getenv("LUNAR_CAPTURE_HOVER_COLUMN")) or 16, point)
		elseif scene == 39 then
			local run = shell.code._scene
			run.say("hover open", tostring(run.doc.binder._popup:isOpen("hover")))
			snap("99-hover")
			run.doc.binder._popup:hide("hover")
			shell.code:toggleEdit()
			run.doc.view:goTo(tonumber(os.getenv("LUNAR_CAPTURE_LIST_LINE")) or 8,
				tonumber(os.getenv("LUNAR_CAPTURE_LIST_COLUMN")) or 14)
			run.say("complete asked", tostring(run.doc.binder:complete()))
		elseif scene == 42 then
			local run = shell.code._scene
			run.say("list open", tostring(run.doc.binder._popup:isOpen("list")),
				"items", tostring(#(run.doc.binder._list_items or {})))
			snap("99-list")
			run.doc.binder:_closeList()
			run.doc.view:goTo(3, 0)
			run.doc.binder:definition(tonumber(os.getenv("LUNAR_CAPTURE_HOVER_LINE")) or 7,
				tonumber(os.getenv("LUNAR_CAPTURE_HOVER_COLUMN")) or 16)
		elseif scene == 45 then
			local run = shell.code._scene
			run.say("definition caret line", tostring((run.doc.view:caret())))
			run.say("pane focus", tostring(pcall(function() shell.panes:toggleFocus() end)),
				tostring(shell.panes:isFocused()))
		elseif scene == 47 then
			snap_window(dlg, "99-focus")
			shell.panes:restoreFocus()
		elseif scene == 49 then
			snap_window(dlg, "99-focus-restored")
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
	if os.getenv("LUNAR_CAPTURE_LOG") then
		local f = io.open(os.getenv("LUNAR_CAPTURE_LOG"), "a")
		if f then f:write(tostring(err), string.char(10)); f:close() end
	end
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
			local pattern=os.getenv("LUNAR_CAPTURE_PAGE_PATTERN")
			if pattern then
				local selected={}; for _,page in ipairs(pages) do if page.title:lower():match(pattern:lower()) then selected[#selected+1]=page end end
				pages=selected
			end
			if os.getenv("LUNAR_CAPTURE_TOOLS_ONLY") then
				local tools = { ["Build Queue"] = true, ["iLO Redfish"] = true, ["Log Parser"] = true,
					["Scan Chain"] = true, ["Black Duck"] = true, ["Time Clock"] = true }
				local selected = {}
				for _, page in ipairs(pages) do if tools[page.title] then selected[#selected + 1] = page end end
				pages = selected
			end
			local width, height = (os.getenv("LUNAR_CAPTURE_SIZE") or ""):match("^(%d+)x(%d+)$")
			if width then
				local IupFFI = require("core.classes.IupFFI")
				if IMGUI then
					local B = require("core.imgui.Runtime").backend()
					B.window("restore")
					B.window("pos", 0, 0)
					B.window("size", tonumber(width), tonumber(height))
				else
					local hwnd = window_of(dlg)
					user32.ShowWindow(hwnd, 9) -- SW_RESTORE
					user32.MoveWindow(hwnd, 0, 0, tonumber(width), tonumber(height), 1)
				end
			end
			fill_lists(dlg)
			for _, p in ipairs(pages) do
				for _, s in ipairs(p.path) do iup.SetAttribute(s.strip, "VALUEPOS", tostring(s.pos)) end
			end
			return iup.DEFAULT
		end
		local page = pages[math.ceil(index / 2)]
		if not page then
			if not os.getenv("LUNAR_CAPTURE_NO_EXTRAS") and extra_scene() then return iup.DEFAULT end
			self.run = "NO"
			iup.ExitLoop()
			return iup.CLOSE
		end
		if index % 2 == 1 then
			for _, s in ipairs(page.path) do iup.SetAttribute(s.strip, "VALUEPOS", tostring(s.pos)) end
			local dev_shell = rawget(_G, "LUNAR_DEV_SHELL")
			if dev_shell and dev_shell.sync_title_bar then dev_shell.sync_title_bar() end
			if dev_shell and dev_shell.tab_changed then dev_shell.tab_changed() end
			fill_lists(dlg) -- an async status may have written a host since the last pass
			iup.Refresh(dlg)
		else
			local slug = page.title:lower():gsub("[^%w]+", "-")
			local IupFFI = require("core.classes.IupFFI")
			local function shoot(suffix)
				local base = string.format("%s/%s-%02d-%s%s", out_dir, prefix, index / 2, slug, suffix)
				save_bmp(window_of(dlg), base .. ".bmp", whole_window)
				dump_tree(dlg, base .. ".tree")
			end
			local fixture = fixtures.for_tab(rawget(_G, "LUNAR_DEV_SHELL") or {}, page.title)
			page.stage = (page.stage or 0) + 1
			if page.stage == 1 then shoot("") end
			if fixture and page.stage <= 2 then
				fixture()
				iup.Refresh(dlg)
				return iup.DEFAULT
			end
			if fixture and page.stage == 3 then shoot("-data") end
			local tool_shell = rawget(_G, "LUNAR_DEV_SHELL")
			local tool = tool_shell and tool_shell.toolPages and tool_shell.toolPages[page.title]
			if tool then
				page.tool_step = (page.tool_step or 0) + 1
				local phase = (page.tool_step - 1) % 3
				local state = ({ "working", "failed" })[math.floor((page.tool_step - 1) / 3) + 1]
				if state then
					if phase == 0 then fixtures.tool_state(tool, state); iup.Refresh(dlg)
					elseif phase == 2 then fixtures.tool_state(tool, state); shoot("-" .. state) end
					return iup.DEFAULT
				end
			end
			-- A page can list named views. Each is shown, given a few ticks for art to arrive, and shot.
			local shell = rawget(_G, "LUNAR_DEV_SHELL")
			local views = shell and shell.pages and shell.pages[page.title]
			if views and views.states then
				page.view_step = (page.view_step or 0) + 1
				local phase = (page.view_step - 1) % 4
				local name = views.states[math.floor((page.view_step - 1) / 4) + 1]
				if name then
					if phase == 0 then
						views.show(name)
						iup.Refresh(dlg)
					elseif phase == 3 then
						shoot("-" .. name)
					end
					return iup.DEFAULT
				end
			end
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
	if os.getenv("LUNAR_CAPTURE_LOG") then
		local f = io.open(os.getenv("LUNAR_CAPTURE_LOG"), "a")
		if f then f:write(tostring(err), string.char(10)); f:close() end
	end
	os.exit(1)
end
