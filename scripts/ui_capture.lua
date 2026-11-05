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
]]
local user32, gdi32, dwmapi = ffi.load("user32"), ffi.load("gdi32"), ffi.load("dwmapi")

-- from_screen copies what is really on screen, title bar and menu included: a popup,
-- and an edit control's cue banner, only paint for WM_PAINT, which PrintWindow does not
-- send. Set LUNAR_CAPTURE_CLIENT=1 for the old client-only shot of a covered window.
local function save_bmp(hwnd, path, from_screen)
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
			save_bmp(ffi.cast("void*", IupFFI.getptr(IupFFI.ptr(dlg), "HWND")),
				string.format("%s/%s-%s.bmp", out_dir, prefix, name), whole_window)
		end
		-- One window's own pixels, whatever is over it: a shared desktop can cover the
		-- status bar, and a screen grab would then show the taskbar instead.
		local function snap_window(window, name)
			save_bmp(ffi.cast("void*", IupFFI.getptr(IupFFI.ptr(window), "HWND")),
				string.format("%s/%s-%s.bmp", out_dir, prefix, name), false)
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
			shell.open_menu()
		elseif scene == 7 then
			snap("92-menu")
			shell.palette:close()
			-- Another window taking focus would dismiss the panel between shots.
			shell.activity._hasFocus = function() return true end
			shell.activity:open()
		elseif scene == 8 then
			snap_window(shell.activity._dialog, "93-activity-empty")
			shell.activity:close()
			activity_scene.start(shell)
		elseif scene == 10 then
			snap_window(dlg, "94-activity-running") -- the bar's slot, with the panel shut
			shell.activity:open()
			shell.activity:_move(2) -- onto the Build Queue row, which offers both actions
		elseif scene == 11 then
			snap_window(shell.activity._dialog, "95-activity")
			snap("95-activity-over-app")
			shell.activity:close()
			activity_scene.finish(shell)
		elseif scene == 12 then
			snap_window(dlg, "96-activity-result")
			-- LUNAR_CAPTURE_CODE=path: a real file in the Code tab, against whatever language
			-- server this machine has, through the path a user takes.
			local code_file = os.getenv("LUNAR_CAPTURE_CODE")
			if not (code_file and shell.code) then return false end
			local opened, why = shell.code:open(code_file, { line = 1 })
			io.stderr:write("ui_capture: open ", tostring(opened), " ", tostring(why), string.char(10))
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
			local width, height = (os.getenv("LUNAR_CAPTURE_SIZE") or ""):match("^(%d+)x(%d+)$")
			if width then
				local IupFFI = require("core.classes.IupFFI")
				local hwnd = ffi.cast("void*", IupFFI.getptr(IupFFI.ptr(dlg), "HWND"))
				user32.ShowWindow(hwnd, 9) -- SW_RESTORE
				user32.MoveWindow(hwnd, 0, 0, tonumber(width), tonumber(height), 1)
			end
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
			local dev_shell = rawget(_G, "LUNAR_DEV_SHELL")
			if dev_shell and dev_shell.sync_title_bar then dev_shell.sync_title_bar() end
			fill_lists(dlg) -- an async status may have written a host since the last pass
			iup.Refresh(dlg)
		else
			local slug = page.title:lower():gsub("[^%w]+", "-")
			local IupFFI = require("core.classes.IupFFI")
			local function shoot(suffix)
				save_bmp(ffi.cast("void*", IupFFI.getptr(IupFFI.ptr(dlg), "HWND")), string.format("%s/%s-%02d-%s%s.bmp",
					out_dir, prefix, index / 2, slug, suffix), whole_window)
			end
			local fixture = fixtures.for_tab(rawget(_G, "LUNAR_DEV_SHELL") or {}, page.title)
			page.stage = (page.stage or 0) + 1
			if page.stage == 1 then shoot("") end
			if fixture and page.stage <= 2 then
				fixture()
				iup.Refresh(dlg)
				return iup.DEFAULT
			end
			if fixture then shoot("-data") end
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
