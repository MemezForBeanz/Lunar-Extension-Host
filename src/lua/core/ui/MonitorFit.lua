--- Keeps the main window's MAXSIZE/MINSIZE on the monitor it is actually on.
--
-- IUP sizes a dialog from its content, and with no MAXSIZE nothing stops the
-- window growing taller than the display (the status bar ended up below the
-- screen edge). The sizes come from `core.lib.desktop.windowFit`; this object
-- applies them:
--
--   1. at startup, from IUP's SCREENSIZE (the PRIMARY monitor's work area,
--      narrowed for an auto-hiding taskbar) -- `startup`
--   2. once the window is shown, for the monitor it opened on -- `refit`
--   3. from the dialog's MOVE_CB, whenever it crosses onto another monitor --
--      `refit` again; a rect equal to the last one returns at once, because
--      MOVE_CB fires on every mouse-move sample of a drag
--
-- Updating MAXSIZE can't shrink a window that is already too tall for a new,
-- shorter monitor (Windows only consults it on the next resize or maximize), so
-- an overflowing window is clamped, or restored and re-maximized when maximized.
-- That path needs a second, shorter monitor to verify by hand.
--
-- @classmod core.ui.MonitorFit

local desktop = require("core.lib.desktop")

local MonitorFit = {}
MonitorFit.__index = MonitorFit

-- Slack over the work height before a window counts as overflowing; a maximized
-- window legitimately extends past the work area by its invisible resize border.
local OVERFLOW_SLACK = 40

--- The startup work area and sizes, before the window exists.
-- @tparam table iup
-- @treturn table `{ work_w, work_h, taskbar, maxsize, minsize }`
function MonitorFit.startup(iup)
	local w, h = 1920, 1080
	local ok, value = pcall(iup.GetGlobal, "SCREENSIZE")
	if ok and type(value) == "string" then
		local sw, sh = value:match("^(%d+)%s*x%s*(%d+)")
		w, h = tonumber(sw) or w, tonumber(sh) or h
	end
	-- SCREENSIZE is the whole screen when the taskbar auto-hides (the shell
	-- reserves nothing), so a maximized window would sit under the bar.
	local uw, uh, bar = desktop.usableArea(w, h)
	w, h = uw or w, uh or h
	local fit = desktop.windowFit({ left = 0, top = 0, right = w, bottom = h })
	return {
		work_w = w, work_h = h, taskbar = bar or { available = false },
		maxsize = fit.maxsize, minsize = fit.minsize,
	}
end

--- @tparam table opts `{ iup, dialog, ffi }`; `ffi` is `core.classes.IupFFI`
--   (or nil: then only `apply` works, `refit` does nothing)
function MonitorFit.new(opts)
	return setmetatable({ _iup = opts.iup, _dialog = opts.dialog, _ffi = opts.ffi, applied = nil }, MonitorFit)
end

--- Size the window for a monitor work rect.
-- @tparam table rect `{ left, top, right, bottom }`
-- @treturn string what it did: `"same"`, `"sized"`, `"clamped"` or `"remaximized"`
function MonitorFit:apply(rect)
	if not rect then return "same" end
	if desktop.rectEq(self.applied, rect) then return "same" end
	self.applied = rect
	local iup, dlg = self._iup, self._dialog

	local fit = desktop.windowFit(rect)
	pcall(iup.SetAttribute, dlg, "MAXSIZE", fit.maxsize)
	pcall(iup.SetAttribute, dlg, "MINSIZE", fit.minsize)

	local ok_rs, rs = pcall(iup.GetAttribute, dlg, "RASTERSIZE")
	local ok_mx, mx = pcall(iup.GetAttribute, dlg, "MAXIMIZED")
	if not (ok_rs and rs and ok_mx) then return "sized" end
	local cur_w, cur_h = rs:match("^(%d+)x(%d+)")
	cur_w, cur_h = tonumber(cur_w), tonumber(cur_h)
	if not cur_h or cur_h <= fit.work_h + OVERFLOW_SLACK then return "sized" end

	if mx == "YES" then
		-- Windows owns a maximized window's size; restore and re-maximize so it
		-- asks WM_GETMINMAXINFO again. PLACEMENT has no setter: IUP applies it
		-- on the next IupShow, hence the Show after each.
		pcall(iup.SetAttribute, dlg, "PLACEMENT", "NORMAL")
		pcall(iup.Show, dlg)
		pcall(iup.SetAttribute, dlg, "PLACEMENT", "MAXIMIZED")
		pcall(iup.Show, dlg)
		return "remaximized"
	end
	pcall(iup.SetAttribute, dlg, "RASTERSIZE", math.min(cur_w or fit.work_w, fit.work_w) .. "x" .. fit.work_h)
	return "clamped"
end

--- Size the window for the monitor it is on now (asks MonitorFromWindow, not
-- the position, so where its origin lands doesn't matter). No-op before the
-- window is mapped or without FFI.
function MonitorFit:refit()
	local ffi = self._ffi
	if not (ffi and ffi.available) then return end
	local ok, hwnd = pcall(function()
		local p = ffi.ptr(self._dialog)
		return p ~= nil and ffi.getptr(p, "HWND") or nil
	end)
	if ok and hwnd ~= nil then
		self:apply(desktop.monitorWorkArea(hwnd))
	end
end

return MonitorFit
