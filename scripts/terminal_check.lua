local iup = require("iup")
local ffi = require("ffi")

-- Nobody is there to dismiss a dialog, and one would stop the run with nothing to show for it.
iup.Message = function(title, text)
	io.stderr:write("ui_capture: ", tostring(title), ": ", tostring(text), string.char(10))
end

local out_dir = (arg and arg[1]) or "."
local prefix = (arg and arg[2]) or "shot"
local plain = os.getenv("LUNAR_TERMINAL_PLAIN") == "1"
if plain then package.preload.sci = function() error("Scintilla disabled for fallback check") end end

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
intptr_t GetWindowLongPtrA(void*, int);
intptr_t SendMessageA(void*, unsigned, uintptr_t, intptr_t);
int SetCursorPos(int, int);
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

-- Native checks and screenshots use the same capture helper as ui_capture.lua.
local mainloop = iup.MainLoop
local log = assert(io.open(out_dir .. "/terminal-check.txt", "w"))
local function record(text) log:write(text, "\n"); log:flush() end
local failures = 0
local function check(value, label)
	record((value and "PASS " or "FAIL ") .. label)
	if not value then failures = failures + 1 end
end
local function size(widget) return iup.GetAttribute(widget, "RASTERSIZE") or "" end
local function height(widget) return tonumber(size(widget):match("x(%d+)$")) or 0 end
local function window(widget)
	local native = require("core.classes.IupFFI")
	return ffi.cast("void*", assert(native.getptr(native.ptr(widget), "WID"), "widget has no native window"))
end
local function no_native_scrollbar(widget)
	return bit.band(tonumber(user32.GetWindowLongPtrA(window(widget), -16)), 0x00300000) == 0
end
local shell, terminal, layout, dialog, stage, started
local function snap(name)
	local native = require("core.classes.IupFFI")
	save_bmp(ffi.cast("void*", native.getptr(native.ptr(dialog), "HWND")), out_dir .. "/" .. prefix .. "-" .. name .. ".bmp", false)
	record(name .. ": panel=" .. size(terminal:widget()) .. " rail=" .. size(layout._rail:widget()) .. " status=" .. size(layout._status:widget()))
end
local function step()
	stage = stage + 1
	if stage == 1 then
		shell = assert(rawget(_G, "LUNAR_DEV_SHELL")); terminal, layout = shell.terminal, shell.view_layout
		dialog = iup.GetDialog(terminal:widget())
		check(terminal._output.rich ~= plain, "requested code view backend available")
		if not layout:terminalVisible() then layout:toggleTerminal() end
		terminal:execute("help")
		terminal:execute("show src/lua/core/lib/LunarShell.lua")
		terminal:_inputText([[headless --for "1"]])
	elseif stage == 2 then
		snap("dark-open"); record("OUTPUT=" .. size(terminal._output:widget()) .. " INPUT=" .. size(terminal._input:widget()))
		check(height(terminal:widget()) == layout:terminalHeight(), "terminal occupies remembered height")
		check(terminal._input:text() == [[headless --for "1"]], "prompt text survives theme and map")
		check(no_native_scrollbar(terminal._output:control()), "terminal output has no Win32 scrollbar styles")
		check(no_native_scrollbar(terminal._input:control()), "terminal prompt has no Win32 scrollbar styles")
		if plain then
			check(iup.GetClassName(terminal._output:widget()) == "flatscrollbox", "fallback uses org-pack flat scroll host")
			check(iup.GetAttribute(terminal._output:widget(), "NATIVETEXTSCROLL") == "YES", "flat scrollbar owns text scrolling")
			terminal._output:scrollToEnd()
			local before = tonumber(iup.GetAttribute(terminal._output:control(), "FIRSTVISIBLELINE"))
			local old_pos = iup.GetAttribute(terminal._output:widget(), "POSY")
			local x, y = tostring(iup.GetAttribute(terminal._output:control(), "SCREENPOSITION")):match("(-?%d+),(-?%d+)")
			x, y = tonumber(x) + 12, tonumber(y) + 12
			iup.SetFocus(terminal._output:control())
			user32.SetCursorPos(x, y)
			user32.SendMessageA(window(terminal._output:control()), 0x020A, 120 * 65536, y * 65536 + x)
			local after = tonumber(iup.GetAttribute(terminal._output:control(), "FIRSTVISIBLELINE"))
			record("WHEEL first=" .. tostring(before) .. "->" .. tostring(after) .. " pos=" .. tostring(old_pos)
				.. "->" .. tostring(iup.GetAttribute(terminal._output:widget(), "POSY"))
				.. " host=" .. tostring(require("core.lib.attr").get(iup, terminal._output:control(), "_IUPFLATSCROLLHOST")))
			check(after < before, "mouse wheel scrolls through the flat host")
			terminal._output:scrollToEnd()
		end
		if terminal._output.rich then
			local sci = require("sci")
			local text = terminal._output:text()
			local position = assert(text:find("function Shell.reference", 1, true)) - 1
			check(sci.send(terminal._output:control(), 2010, position, 0) == terminal._output._role_styles.keyword,
				"printed Lua uses CodeView lexer colours")
			sci.send(terminal._output:control(), 2160, 0, 5)
			terminal._buffer:append("streamed output\n")
			terminal:_render()
			check(sci.send(terminal._output:control(), 2143, 0, 0) == 0 and sci.send(terminal._output:control(), 2145, 0, 0) == 5,
				"streaming preserves selected text")
		end
		layout:setTerminalHeight(360); layout:saveTerminalHeight()
		terminal:execute("headless --for 0.1 --dev --until-idle")
	elseif stage == 3 then
		check(not terminal._process, "bundled Lunar CLI finishes and handle closes")
		check(terminal._output:text():find("Lunar CLI exited 0", 1, true), "streamed CLI output and success exit")
		terminal:execute("headless --for 30 --dev")
	elseif stage == 4 then
		check(terminal._process ~= nil, "long CLI run is active")
		terminal:_key(iup.K_cC)
		check(terminal._process == nil, "Ctrl+C cancels running CLI")
		check(terminal._output:text():find("^C", 1, true), "cancellation printed")
		terminal:execute("extensions"); terminal:execute("lsp"); terminal:execute("problems")
		layout._rail:toggle()
		snap("bars-before")
		layout:toggleBars()
		local sample = iup.timer({ TIME = "65" })
		function sample:action_cb()
			self.run = "NO"
			local width = tonumber(size(layout._rail:widget()):match("^(%d+)x"))
			check(width > 0 and width < 176, "native rail width changes during motion")
			snap("bars-mid")
			local at = layout._bar_progress
			layout:toggleBars()
			check(layout._bar_progress == at, "rapid native reversal starts at current frame")
			layout:toggleBars()
			return iup.DEFAULT
		end
		sample.run = "YES"
	elseif stage == 5 then
		snap("bars-hidden")
		check(iup.GetAttribute(layout._rail:widget(), "VISIBLE") == "NO", "rail hidden")
		check(iup.GetAttribute(layout._status:widget(), "VISIBLE") == "NO", "status contents hidden")
		local client = tonumber((iup.GetAttribute(dialog, "CLIENTSIZE") or ""):match("x(%d+)$"))
		check(shell.shell_budget.cap == client - 40 - 24, "page may fill the status bar's space")
		layout:toggleBars()
	elseif stage == 6 then
		snap("bars-restored")
		check(size(layout._rail:widget()):match("^176x"), "expanded sidebar restored expanded")
		check(height(layout._status:widget()) > 0, "status bar restored")
		shell.host._theme_mgr:apply("lunar_light")
		terminal:clear(); terminal:execute("help"); terminal:execute("version")
		terminal:_inputText([[show "src/lua/core/lib/LunarShell.lua"]])
	elseif stage == 7 then
		snap("light-open")
		check(no_native_scrollbar(terminal._output:control()), "theme switch keeps native terminal bars disabled")
		check(terminal._output._colors.surface ~= "", "code palette recalculated")
		terminal:maximize()
	elseif stage == 8 then
		check(height(terminal:widget()) > 360, "maximize grows panel")
		terminal:maximize()
		layout:toggleTerminal()
	elseif stage == 9 then
		check(iup.GetAttribute(terminal:widget(), "VISIBLE") == "NO", "terminal closes completely")
		snap("terminal-closed")
		layout:toggleTerminal()
	elseif stage == 10 then
		check(height(terminal:widget()) == 360, "terminal reopens at resized height")
		snap("light-resized")
		record("RESULT " .. failures .. " failures")
		log:close(); iup.ExitLoop()
	end
end
iup.MainLoop = function()
	stage = 0
	local timer = iup.timer({ TIME = "800" })
	function timer:action_cb()
		local ok, why = pcall(step)
		if not ok then record("ERROR " .. tostring(why)); log:close(); os.exit(2) end
		return iup.DEFAULT
	end
	timer.run = "YES"
	started = true
	return mainloop()
end
local ok, why = pcall(dofile, (LUNAR_SOURCE_DIR or ".") .. "/src/lua/core/main.lua")
if not ok then record("STARTUP ERROR " .. tostring(why)); log:close(); os.exit(3) end
if not started then record("MainLoop was not reached") end
os.exit(failures == 0 and 0 or 1)
