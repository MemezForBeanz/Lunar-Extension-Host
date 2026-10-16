--- Desktop geometry: work area and Windows taskbar state.
--
-- `SPI_GETWORKAREA` (what IUP exposes as the SCREENSIZE global) is the right
-- answer for a *docked* taskbar -- the shell subtracts the bar and a maximized
-- window lands above it.
--
-- It is the WRONG answer for an AUTO-HIDE taskbar. When auto-hide is on the shell
-- reserves nothing, so the work area equals the whole screen; a maximized window
-- fills the display and the bar slides out ON TOP of its bottom edge whenever the
-- pointer goes near. No resize event is raised, because nothing about the work
-- area changed -- which is exactly why the app "doesn't react" when the taskbar
-- comes up, and why the status bar ends up underneath it.
--
-- Windows only tells you this through the shell app-bar API, so that is what this
-- module calls:
--   * `ABM_GETSTATE`      -> is the taskbar auto-hide / always-on-top?
--   * `ABM_GETTASKBARPOS` -> which edge it is docked to, and how thick it is.
--
-- Everything is best-effort: without LuaJIT FFI (or on a future Windows that
-- refuses the call) `taskbar()` reports `available = false` and callers fall back
-- to the plain work area, which is the old behaviour.
--
-- @module core.lib.desktop

local M = {}

local ok_ffi, ffi = pcall(require, "ffi")

local shell32, user32
if ok_ffi and ffi then
	-- cdef is per-Lua-state and raises if redeclared; pcall keeps a repeat
	-- require harmless (same pattern as core.lib.filescan).
	pcall(ffi.cdef, [[
		typedef struct { long left, top, right, bottom; } LUNAR_RECT;
		typedef struct {
			unsigned long  cbSize;
			void*          hWnd;
			unsigned int   uCallbackMessage;
			unsigned int   uEdge;
			LUNAR_RECT      rc;
			long long      lParam;
		} LUNAR_APPBARDATA;
		unsigned long long SHAppBarMessage(unsigned long dwMessage, LUNAR_APPBARDATA* pData);
		int SystemParametersInfoA(unsigned int uiAction, unsigned int uiParam, void* pvParam, unsigned int fWinIni);
	]])
	-- Separate cdef block so a re-require (which pcall swallows above) doesn't
	-- take down these unrelated declarations with it.
	pcall(ffi.cdef, [[
		void* MonitorFromWindow(void* hwnd, unsigned long dwFlags);
		typedef struct {
			unsigned long cbSize;
			LUNAR_RECT     rcMonitor;
			LUNAR_RECT     rcWork;
			unsigned long dwFlags;
		} LUNAR_MONITORINFO;
		int GetMonitorInfoA(void* hMonitor, LUNAR_MONITORINFO* lpmi);
	]])
	local ok_shell, s = pcall(ffi.load, "shell32")
	if ok_shell then shell32 = s end
	local ok_user, u = pcall(ffi.load, "user32")
	if ok_user then user32 = u end
end

local ABM_GETSTATE       = 0x00000004
local ABM_GETTASKBARPOS  = 0x00000005
local ABS_AUTOHIDE       = 0x0000001
local SPI_GETWORKAREA    = 0x0030
local EDGE_NAME = { [0] = "left", [1] = "top", [2] = "right", [3] = "bottom" }
local MONITOR_DEFAULTTONEAREST = 2

--- The shell work area in pixels (screen minus any DOCKED taskbar).
-- @treturn number width
-- @treturn number height
function M.workArea()
	if not (ok_ffi and user32) then return nil end
	local rect = ffi.new("LUNAR_RECT[1]")
	local ok = pcall(function()
		return user32.SystemParametersInfoA(SPI_GETWORKAREA, 0, rect, 0)
	end)
	if not ok then return nil end
	local w = rect[0].right - rect[0].left
	local h = rect[0].bottom - rect[0].top
	if w <= 0 or h <= 0 then return nil end
	return w, h
end

--- Taskbar state.
--
-- @treturn table `{ available, autohide, edge, thickness }` where `edge` is one of
--   `"left"|"top"|"right"|"bottom"` and `thickness` is its size in pixels along
--   the docked axis. `available` is false when the shell could not be queried.
function M.taskbar()
	local info = { available = false, autohide = false, edge = nil, thickness = 0 }
	if not (ok_ffi and shell32) then return info end

	local abd = ffi.new("LUNAR_APPBARDATA[1]")
	abd[0].cbSize = ffi.sizeof("LUNAR_APPBARDATA")

	local ok_state, state = pcall(function()
		return tonumber(shell32.SHAppBarMessage(ABM_GETSTATE, abd))
	end)
	if not ok_state or not state then return info end
	info.available = true
	-- ABS_AUTOHIDE is a bit flag; ABS_ALWAYSONTOP occupies the other one.
	info.autohide = (math.floor(state / ABS_AUTOHIDE) % 2) == 1

	local ok_pos = pcall(function()
		return shell32.SHAppBarMessage(ABM_GETTASKBARPOS, abd)
	end)
	if ok_pos then
		info.edge = EDGE_NAME[tonumber(abd[0].uEdge)]
		local r = abd[0].rc
		if info.edge == "left" or info.edge == "right" then
			info.thickness = math.max(0, r.right - r.left)
		else
			info.thickness = math.max(0, r.bottom - r.top)
		end
	end
	return info
end

--- Area a window should occupy: the shell work area.
--
-- An AUTO-HIDE taskbar is deliberately NOT subtracted. It is tempting to reserve
-- its thickness so it can never overlap the UI, but that leaves a permanent dead
-- strip of desktop below a "maximized" window -- visibly not full screen, which is
-- worse than the problem it solves. Windows itself lets an auto-hide bar float
-- over maximized windows; every other application behaves this way, and the bar is
-- hidden except while the user is deliberately pointing at it.
--
-- The taskbar info is still returned, because it is worth reporting in the
-- diagnostics and a caller may want to make a different trade-off.
--
-- @tparam number fallback_w used when the shell cannot be queried
-- @tparam number fallback_h
-- @treturn number width
-- @treturn number height
-- @treturn table the `taskbar()` info, for diagnostics
function M.usableArea(fallback_w, fallback_h)
	local w, h = M.workArea()
	w = w or fallback_w or 1920
	h = h or fallback_h or 1080
	return w, h, M.taskbar()
end

--- Work area of the monitor that a given window is currently on.
--
-- `SPI_GETWORKAREA` (IUP SCREENSIZE) only reports the PRIMARY monitor. On a
-- machine with a 1080-tall primary and a 768-tall secondary, `WORK_H = 1080`
-- and `MAXSIZE = 1120` -- Windows allows the window to be 1120px tall on a
-- 768px screen, so the status bar overflows below the screen edge and is
-- invisible.  This function is the fix: it resolves the monitor the window is
-- ACTUALLY ON via `MonitorFromWindow` and returns that monitor's work rect.
--
-- `GetMonitorInfo` returns physical pixels, the same space `RASTERSIZE` and
-- `MAXSIZE` use, so no DPI conversion is needed here.  (The manifest declares
-- PerMonitorV2, which means Windows never scale-lies to the process.)
--
-- cbSize MUST be set before calling `GetMonitorInfoA` or the function returns
-- FALSE silently -- it is a versioned struct and 0 signals "unknown version".
--
-- @tparam cdata hwnd A `void*` HWND from `IupFFI.getptr(p, "HWND")`.
-- @treturn table|nil `{ left, top, right, bottom }` of the work rect,
--   or `nil` when FFI / the call is unavailable (callers fall back to the
--   startup-computed primary-monitor values).
function M.monitorWorkArea(hwnd)
	if not (ok_ffi and ffi and user32) then return nil end
	if not hwnd then return nil end
	local hmon
	local ok1 = pcall(function()
		hmon = user32.MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST)
	end)
	if not ok1 or not hmon then return nil end
	local mi = ffi.new("LUNAR_MONITORINFO[1]")
	mi[0].cbSize = ffi.sizeof("LUNAR_MONITORINFO")
	local ok2, ret = pcall(function()
		return user32.GetMonitorInfoA(hmon, mi)
	end)
	if not ok2 or ret == 0 then return nil end
	local r = mi[0].rcWork
	return {
		left   = tonumber(r.left),
		top    = tonumber(r.top),
		right  = tonumber(r.right),
		bottom = tonumber(r.bottom),
	}
end

--- Whether two work-area rects describe the same monitor geometry.
--
-- Used by the MOVE_CB guard in main.lua: MOVE_CB fires on every mouse-move
-- sample during a drag, so attribute writes must be gated on an actual change.
--
-- @tparam table|nil a `{ left, top, right, bottom }`
-- @tparam table|nil b
-- @treturn boolean
function M.rectEq(a, b)
	if a == nil or b == nil then return a == b end
	return a.left == b.left and a.top == b.top
		and a.right == b.right and a.bottom == b.bottom
end

-- MIN_W and MIN_H bounds mirrored from main.lua so windowFit is the single
-- source of truth for this arithmetic and the spec can import it without
-- pulling in main.lua.
local FIT_W_MAX  = 700   -- MINSIZE width ceiling
local FIT_W_MIN  = 400   -- MINSIZE width floor
local FIT_H_MAX  = 500   -- MINSIZE height ceiling
local FIT_H_MIN  = 320   -- MINSIZE height floor
local FIT_SLACK  = 40    -- MAXSIZE slack over work height (resize-border, see main.lua)

--- Compute the IUP MAXSIZE and MINSIZE attribute strings for the main dialog
-- based on a monitor work-area rect.
--
-- The `+40` slack in MAXSIZE is REQUIRED -- a maximised window on Windows 10/11
-- deliberately extends beyond the work area by the invisible resize border on
-- every side.  Capping at exactly `work_h` would forbid that expansion and the
-- window would maximise to slightly less than the screen.
--
-- A MINSIZE taller than the work area is unsatisfiable: the window cannot
-- shrink to fit, so its bottom is forced off-screen.  MIN_H is clamped to
-- `work_h - 80` (leaving a little slack) rather than asserting 500 blindly.
--
-- @tparam table rect `{ left, top, right, bottom }` work-area rect in physical px
-- @treturn table `{ maxsize, minsize, min_w, min_h, work_w, work_h }`
function M.windowFit(rect)
	local work_w = rect.right  - rect.left
	local work_h = rect.bottom - rect.top
	local min_w  = math.min(FIT_W_MAX, math.max(FIT_W_MIN, work_w - 80))
	local min_h  = math.min(FIT_H_MAX, math.max(FIT_H_MIN, work_h - 80))
	return {
		maxsize = "65535x" .. (work_h + FIT_SLACK),
		minsize = min_w .. "x" .. min_h,
		min_w   = min_w,
		min_h   = min_h,
		work_w  = work_w,
		work_h  = work_h,
	}
end

return M
