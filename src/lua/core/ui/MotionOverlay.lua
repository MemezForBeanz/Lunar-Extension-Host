--- Click-through layered window for compositing UI motion over the live UI.
--
-- IUP has no notion of a free-floating drawing layer: every widget is laid out by
-- its parent, so there is nowhere to draw a drag ghost that crosses widget
-- boundaries, and no way to slide one page over another. This module supplies
-- that missing layer as a real Win32 window sitting above the dialog.
--
-- ### Why a separate window, and why click-through
--
-- The overlay covers the very controls the user is interacting with -- the tab
-- strip they are dragging along, the page they are switching away from. A normal
-- window there would swallow every mouse event and break the gesture it exists to
-- illustrate.
--
-- `WS_EX_TRANSPARENT` solves exactly that: the window renders, but hit-testing
-- falls straight through to whatever is beneath. Combined with:
--
--   * `WS_EX_LAYERED` -- required for `WS_EX_TRANSPARENT` to behave, and gives
--     per-window alpha for free
--   * `WS_EX_NOACTIVATE` -- never steals focus, so the user's caret and keyboard
--     target survive an animation
--   * `WS_EX_TOOLWINDOW` -- keeps it out of alt-tab and the taskbar
--
-- ...the result is a surface that is visible, correctly z-ordered with the app,
-- and completely inert.
--
-- ### Painting: raw GDI, double-buffered, deliberately not IupDraw
--
-- IUP's own `IupDraw*` API would be the obvious choice, but it cannot be mixed
-- with the bitmap blitting this module exists to do. `IupDrawBegin` allocates a
-- private offscreen bitmap and only presents it on `IupDrawEnd`, and it does not
-- expose that intermediate DC -- so a `BitBlt` aimed at the window would simply be
-- overwritten the moment `IupDrawEnd` ran.
--
-- Instead the canvas's `HDC_WMPAINT` attribute (the live `WM_PAINT` device
-- context) is read directly through `core.classes.IupFFI`, and every frame is
-- composited into this module's **own** back buffer before a single `BitBlt`
-- presents it. One buffer, one present, no tearing, and snapshots and vector
-- shapes share one coordinate space.
--
-- ### Snapshots
--
-- Sliding one page over another needs a *picture* of each page, because the real
-- widgets cannot be in two places at once. `capture()` blits a widget's pixels
-- into an offscreen bitmap, falling back to `PrintWindow` with
-- `PW_RENDERFULLCONTENT` for controls that render nothing into a plain `BitBlt`
-- (typically because they only paint on `WM_PRINT`).
--
-- GDI objects are a finite, process-wide resource, and leaking them degrades the
-- whole desktop rather than just this app. Every snapshot therefore carries an
-- explicit `release()` **and** an `ffi.gc` finaliser, so a forgotten release on an
-- error path still cannot leak.
--
-- ### Failing closed
--
-- Everything here is best-effort decoration. `available()` gates the module and
-- latches false if the FFI, the HWND, the layered style or a capture ever fails,
-- so a broken environment is probed once rather than every frame. Callers then
-- take their instant, non-animated path and lose the animation, nothing else.
--
-- Not reachable from the busted suite: this needs a live IUP dialog and a real
-- window handle. `scripts/motion_check.lua` exercises it against the running host.
--
-- @classmod core.ui.MotionOverlay

local class = require("middleclass")

local MotionOverlay = class("MotionOverlay")

local ok_ffi, ffi = pcall(require, "ffi")
if not ok_ffi then ffi = nil end

local ok_iupffi, IupFFI = pcall(require, "core.classes.IupFFI")
if not ok_iupffi then IupFFI = nil end

local user32, gdi32
local ffi_ready = false

if ffi then
	-- cdef is per-Lua-state and raises on redeclaration; pcall keeps a stray
	-- re-require harmless. Types use fixed-width ints rather than the Windows
	-- typedefs so this block stays independent of any other cdef in the process.
	pcall(ffi.cdef, [[
		typedef struct { long left, top, right, bottom; } LUNAR_RECT;
		typedef struct { long x, y; } LUNAR_POINT;

		void*         GetDC(void *hwnd);
		int           ReleaseDC(void *hwnd, void *hdc);
		long          GetWindowLongA(void *hwnd, int index);
		long          SetWindowLongA(void *hwnd, int index, long newlong);
		int           SetLayeredWindowAttributes(void *hwnd, unsigned long key,
		                                         unsigned char alpha, unsigned long flags);
		int           GetClientRect(void *hwnd, LUNAR_RECT *rect);
		int           ClientToScreen(void *hwnd, LUNAR_POINT *point);
		int           PrintWindow(void *hwnd, void *hdc, unsigned int flags);
		int           SetWindowPos(void *hwnd, void *after, int x, int y,
		                           int cx, int cy, unsigned int flags);
		int           ShowWindow(void *hwnd, int cmd);
		int           FillRect(void *hdc, const LUNAR_RECT *rect, void *brush);

		void*         CreateCompatibleDC(void *hdc);
		void*         CreateCompatibleBitmap(void *hdc, int cx, int cy);
		void*         CreateSolidBrush(unsigned long color);
		void*         SelectObject(void *hdc, void *obj);
		int           DeleteObject(void *obj);
		int           DeleteDC(void *hdc);
		int           BitBlt(void *dst, int x, int y, int cx, int cy,
		                     void *src, int x1, int y1, unsigned long rop);

		/* Passed BY VALUE, and it is exactly four bytes, so the ABI hands it over
		   in a register like an int. Declared with the fields spelled out rather
		   than as a uint32 so the call site reads as the documented struct. */
		typedef struct {
			unsigned char BlendOp, BlendFlags, SourceConstantAlpha, AlphaFormat;
		} LUNAR_BLENDFUNCTION;
		int           AlphaBlend(void *dst, int x, int y, int cx, int cy,
		                         void *src, int x1, int y1, int cx1, int cy1,
		                         LUNAR_BLENDFUNCTION blend);
	]])

	local ok = pcall(function()
		user32 = ffi.load("user32")
		gdi32  = ffi.load("gdi32")
		local _ = user32.GetDC
		local _ = gdi32.BitBlt
	end)
	ffi_ready = ok and true or false
	if not ok then user32, gdi32 = nil, nil end
end

-- Per-pixel-uniform alpha compositing, loaded separately from the rest of GDI.
--
-- `AlphaBlend` lives in msimg32.dll, not gdi32.dll, and is the one call here that
-- is not guaranteed present on every Windows the app might meet. It is also
-- strictly a nicety -- a cross-fade degrades to a hard cut, which still reads as a
-- transition. So it gets its own load and its own availability flag rather than
-- being allowed to fail the whole overlay.
local msimg32, blend_ready = nil, false
if ffi_ready then
	local ok = pcall(function()
		msimg32 = ffi.load("msimg32")
		local _ = msimg32.AlphaBlend
	end)
	blend_ready = ok and true or false
	if not ok then msimg32 = nil end
end

local AC_SRC_OVER = 0x00

-- Win32 constants, named rather than inlined so the intent survives.
local GWL_EXSTYLE          = -20
local WS_EX_LAYERED        = 0x00080000
local WS_EX_TRANSPARENT    = 0x00000020
local WS_EX_NOACTIVATE     = 0x08000000
local WS_EX_TOOLWINDOW     = 0x00000080
local LWA_ALPHA            = 0x00000002
local SRCCOPY              = 0x00CC0020
local PW_RENDERFULLCONTENT = 0x00000002

local SWP_NOACTIVATE = 0x0010
local SWP_SHOWWINDOW = 0x0040
local SW_HIDE        = 0
-- HWND_TOP is the literal null handle, which SetWindowPos reads as "top of the
-- Z-order" only when SWP_NOZORDER is absent.
local HWND_TOP       = nil

--- Is the native overlay machinery usable in this process at all?
-- @treturn boolean
-- @usage if MotionOverlay.supported() then ... end
function MotionOverlay.static.supported()
	return (ffi_ready and IupFFI ~= nil and IupFFI.available) and true or false
end

-- "R G B" -> Win32 COLORREF (0x00BBGGRR). Accepts "#RRGGBB" too.
local function colorref(spec)
	if type(spec) ~= "string" then return 0 end
	local r, g, b = spec:match("^%s*(%d+)%s+(%d+)%s+(%d+)")
	if not r then
		local hex = spec:match("^#?(%x%x%x%x%x%x)$")
		if hex then
			r = tonumber(hex:sub(1, 2), 16)
			g = tonumber(hex:sub(3, 4), 16)
			b = tonumber(hex:sub(5, 6), 16)
		end
	end
	r = tonumber(r) or 0
	g = tonumber(g) or 0
	b = tonumber(b) or 0
	return r + g * 256 + b * 65536
end

--- Create an overlay bound to a host dialog.
--
-- `opts` fields:
--
--   * `iup` -- the IUP binding (required)
--   * `dialog` -- the main application dialog this overlay floats above
--   * `log` -- optional `fn(msg)` for diagnostics
--
-- Construction is cheap and creates no window; the window appears lazily on the
-- first `show()`, so an app that never animates never pays for it.
--
-- @tparam table opts construction options (see above)
function MotionOverlay:initialize(opts)
	opts = opts or {}
	self._iup    = opts.iup
	self._dialog = opts.dialog
	self._log    = opts.log

	self._dlg     = nil
	self._canvas  = nil
	self._hwnd    = nil
	self._visible = false
	self._failed  = false
	self._draw    = nil    -- current frame composer
	self._rect    = { x = 0, y = 0, w = 0, h = 0 }

	self._back    = nil    -- { dc, bitmap, old, w, h } back buffer
	self._brushes = {}     -- COLORREF -> HBRUSH cache
	self._target  = nil    -- back-buffer DC, valid only during a frame
end

function MotionOverlay:_note(msg)
	if self._log then pcall(self._log, "[MotionOverlay] " .. tostring(msg)) end
end

--- Can this overlay be used right now?
-- Latches false after any failure, so a broken environment costs one probe.
-- @treturn boolean
function MotionOverlay:available()
	return MotionOverlay.supported() and not self._failed and self._iup ~= nil
end

function MotionOverlay:_fail(why)
	if not self._failed then
		self._failed = true
		self:_note("disabled: " .. tostring(why))
	end
	return nil
end

-- =======================================================================
-- WINDOW
-- =======================================================================

-- Resolve an IUP widget's HWND as a void* cdata.
function MotionOverlay:_hwndOf(widget)
	if not widget then return nil end
	local p = IupFFI.ptr(widget)
	if p == nil then return nil end
	return IupFFI.getptr(p, "HWND")
end

-- Build the overlay dialog + canvas and apply the extended window styles.
function MotionOverlay:_ensureWindow()
	if not self:available() then return nil end
	if self._hwnd then return self._hwnd end

	local iup = self._iup
	local this = self

	local ok, err = pcall(function()
		local canvas = iup.canvas({ BORDER = "NO", EXPAND = "YES" })
		function canvas:action()
			this:_paint()
			return iup.DEFAULT
		end

		local dlg = iup.dialog({
			canvas,
			BORDER       = "NO",
			RESIZE       = "NO",
			MAXBOX       = "NO",
			MINBOX       = "NO",
			MENUBOX      = "NO",
			TOOLBOX      = "YES",
			-- Parented to the app dialog so it minimises, restores and z-orders
			-- with the application instead of floating over unrelated programs.
			PARENTDIALOG = this._dialog,
		})

		iup.Map(dlg)
		this._dlg    = dlg
		this._canvas = canvas
	end)
	if not ok then return self:_fail("window creation failed: " .. tostring(err)) end

	local hwnd = self:_hwndOf(self._dlg)
	if hwnd == nil then return self:_fail("no HWND on overlay dialog") end

	local styled = pcall(function()
		local ex = user32.GetWindowLongA(hwnd, GWL_EXSTYLE)
		ex = bit.bor(ex, WS_EX_LAYERED, WS_EX_TRANSPARENT, WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW)
		user32.SetWindowLongA(hwnd, GWL_EXSTYLE, ex)
		user32.SetLayeredWindowAttributes(hwnd, 0, 255, LWA_ALPHA)
	end)
	if not styled then return self:_fail("could not apply layered styles") end

	self._hwnd = hwnd
	return hwnd
end

--- Screen rectangle of a widget: `x, y, w, h`, or `nil`.
--
-- ### Why there are two paths
--
-- `SCREENPOSITION` is the obvious source and works for controls that own a native
-- window. It is **not** set for IUP's pure-layout containers -- `vbox`, `hbox`,
-- `zbox` -- because those have no window to ask. A tab page is very often exactly
-- one of those, so relying on `SCREENPOSITION` alone silently fails on precisely
-- the widget this module most needs to measure.
--
-- ### POSITION is relative to the PARENT, not to the dialog
--
-- The fallback used to read `POSITION` and add the dialog's client origin, on the
-- understanding that `POSITION` was dialog-relative. It is not: IUP reports it
-- relative to the immediate parent. For a widget parented directly to the dialog's
-- top-level box the two happen to coincide, which is why that read survived so
-- long -- but for anything nested it is wrong by the sum of every intermediate
-- offset.
--
-- That produced a very specific bug. A tab page inside a **group** sub-strip and a
-- page of the root strip both report `POSITION = 1,27` -- identical, each being
-- 1,27 within its own tabs control -- so both resolved to the same rectangle near
-- the top of the window. Switching a sub-tab therefore composited over, and
-- captured, the tab strips themselves, and the top-level tab bar appeared to slide
-- along with the page. Switching between groups looked correct only by luck: there
-- the page IS the sub-strip, which owns a window and so answered `SCREENPOSITION`
-- directly.
--
-- The fix is to accumulate `POSITION` up the ancestry until something can actually
-- say where it is on screen -- either a widget with a real `SCREENPOSITION`, or the
-- dialog, whose client origin is asked for separately (its own `SCREENPOSITION` is
-- the outer window, which includes the title bar and border).
--
-- Read fresh on every use rather than cached: between two animations the window
-- can be moved, resized, or dragged to a display with different DPI, and a stale
-- rectangle would place the overlay somewhere the content is not.
--
-- @tparam ihandle widget any mapped IUP widget
-- @treturn number|nil x
-- @treturn number y
-- @treturn number w
-- @treturn number h
function MotionOverlay:rectOf(widget)
	local iup = self._iup
	if not widget then return nil end

	local ok_size, size = pcall(iup.GetAttribute, widget, "RASTERSIZE")
	if not ok_size or type(size) ~= "string" then return nil end
	local sw, sh = size:match("^(%d+)x(%d+)")
	if not sw then return nil end
	local w, h = tonumber(sw), tonumber(sh)

	local sx, sy = MotionOverlay.screenPos(iup, widget)
	if sx then return sx, sy, w, h end

	local anchor, kind, ax, ay = MotionOverlay.anchorOffset(iup, widget)
	if not anchor then return nil end

	if kind == "screen" then
		local px, py = MotionOverlay.screenPos(iup, anchor)
		if not px then return nil end
		return px + ax, py + ay, w, h
	end

	-- Anchored on the dialog: its client origin, not its SCREENPOSITION.
	local ox, oy = self:_clientOrigin(anchor)
	if not ox then return nil end
	return ox + ax, oy + ay, w, h
end

--- A widget's `SCREENPOSITION` as two numbers, or `nil` when it has none.
-- @tparam userdata iup the IUP binding
-- @tparam ihandle widget
-- @treturn number|nil x
-- @treturn number y
function MotionOverlay.screenPos(iup, widget)
	local ok, pos = pcall(iup.GetAttribute, widget, "SCREENPOSITION")
	if not ok or type(pos) ~= "string" then return nil end
	local x, y = pos:match("^(%-?%d+),(%-?%d+)")
	if not x then return nil end
	return tonumber(x), tonumber(y)
end

--- Walk up from `widget` to something that knows where it is on screen.
--
-- Accumulates each step's parent-relative `POSITION` on the way up and stops at
-- the first ancestor that either owns a window (has a `SCREENPOSITION`) or is the
-- dialog. Returns that ancestor, which of the two it is, and the total offset from
-- it down to `widget`.
--
-- Split out from `rectOf` and written against the injected `iup` table rather than
-- `self` so the traversal -- the part that was wrong, and the part with no FFI in
-- it -- is reachable from the busted suite.
--
-- @tparam userdata iup the IUP binding
-- @tparam ihandle widget
-- @treturn ihandle|nil anchor the ancestor to measure from
-- @treturn string kind `"screen"` or `"dialog"`
-- @treturn number ax accumulated X offset from anchor to widget
-- @treturn number ay accumulated Y offset
function MotionOverlay.anchorOffset(iup, widget)
	-- Bounded rather than `while true`: a malformed tree (or a binding that hands
	-- back a cycle) would otherwise hang the UI thread inside a repaint.
	local MAX_DEPTH = 64
	local ax, ay = 0, 0
	local node = widget

	for _ = 1, MAX_DEPTH do
		local ok_pos, pos = pcall(iup.GetAttribute, node, "POSITION")
		if not ok_pos or type(pos) ~= "string" then return nil end
		local px, py = pos:match("^(%-?%d+),(%-?%d+)")
		if not px then return nil end
		ax = ax + tonumber(px)
		ay = ay + tonumber(py)

		local ok_parent, parent = pcall(iup.GetParent, node)
		if not ok_parent or parent == nil then return nil end

		local ok_cls, cls = pcall(iup.GetClassName, parent)
		if ok_cls and cls == "dialog" then
			return parent, "dialog", ax, ay
		end
		if MotionOverlay.screenPos(iup, parent) then
			return parent, "screen", ax, ay
		end

		node = parent
	end

	return nil
end

-- Screen coordinates of a window's client-area origin, or nil.
function MotionOverlay:_clientOrigin(widget)
	local hwnd = self:_hwndOf(widget)
	if hwnd == nil then return nil end
	local origin = ffi.new("LUNAR_POINT[1]")
	origin[0].x, origin[0].y = 0, 0
	if user32.ClientToScreen(hwnd, origin) == 0 then return nil end
	return tonumber(origin[0].x), tonumber(origin[0].y)
end

-- =======================================================================
-- BACK BUFFER
-- =======================================================================

function MotionOverlay:_releaseBack()
	local b = self._back
	if not b then return end
	if b.old and b.dc ~= nil then pcall(gdi32.SelectObject, b.dc, b.old) end
	if b.bitmap ~= nil then pcall(gdi32.DeleteObject, b.bitmap) end
	if b.dc ~= nil then pcall(gdi32.DeleteDC, b.dc) end
	self._back = nil
end

function MotionOverlay:_ensureBack(hdc, w, h)
	local b = self._back
	if b and b.w == w and b.h == h then return b end
	self:_releaseBack()

	local nb = { w = w, h = h }
	local ok = pcall(function()
		nb.dc = gdi32.CreateCompatibleDC(hdc)
		if nb.dc == nil then error("CreateCompatibleDC failed") end
		nb.bitmap = gdi32.CreateCompatibleBitmap(hdc, w, h)
		if nb.bitmap == nil then error("CreateCompatibleBitmap failed") end
		nb.old = gdi32.SelectObject(nb.dc, nb.bitmap)
	end)
	if not ok then
		if nb.bitmap ~= nil then pcall(gdi32.DeleteObject, nb.bitmap) end
		if nb.dc ~= nil then pcall(gdi32.DeleteDC, nb.dc) end
		return nil
	end
	self._back = nb
	return nb
end

function MotionOverlay:_brush(value)
	local cached = self._brushes[value]
	if cached ~= nil then return cached end
	local ok, brush = pcall(gdi32.CreateSolidBrush, value)
	if not ok or brush == nil then return nil end
	self._brushes[value] = brush
	return brush
end

-- Composite one frame: run the caller's composer against the back buffer, then
-- present it with a single BitBlt.
function MotionOverlay:_paint()
	local canvas = self._canvas
	if not canvas then return end

	local p = IupFFI.ptr(canvas)
	if p == nil then return end
	local hdc = IupFFI.getptr(p, "HDC_WMPAINT")
	if hdc == nil then return end

	local hwnd = self:_hwndOf(canvas)
	if hwnd == nil then return end
	local rect = ffi.new("LUNAR_RECT[1]")
	if user32.GetClientRect(hwnd, rect) == 0 then return end
	local w = rect[0].right - rect[0].left
	local h = rect[0].bottom - rect[0].top
	if w <= 0 or h <= 0 then return end

	local back = self:_ensureBack(hdc, w, h)
	if not back then return end

	self._target = back.dc
	local fn = self._draw
	if fn then pcall(fn, self) end
	self._target = nil

	pcall(gdi32.BitBlt, hdc, 0, 0, w, h, back.dc, 0, 0, SRCCOPY)
end

--- Create the overlay window now, ahead of any animation.
--
-- Window creation is the one genuinely dangerous thing this module does. Creating
-- and mapping a native window from inside a mouse-event callback -- which is where
-- the first animation of a drag would otherwise trigger it, while the source
-- control holds the Win32 mouse capture -- is exactly the kind of re-entrancy that
-- `core.classes.TabOrder:_scheduleDrop` was already written to avoid for widget
-- surgery. It presented the same way here: a hard crash a drag or two into a
-- session.
--
-- Calling this once at startup, when nothing is in flight, means every later
-- `show()` is only a `SetWindowPos` on a window that already exists.
--
-- Safe to call more than once, and safe to skip -- `show()` still creates the
-- window on demand if it has to.
--
-- @treturn boolean true when the window is ready
-- @usage overlay:prepare()   -- once, after the main dialog is shown
function MotionOverlay:prepare()
	if not self:available() then return false end
	return self:_ensureWindow() ~= nil
end

--- Show the overlay covering `widget`'s screen rectangle.
--
-- `draw` is invoked once per repaint with the overlay as its only argument, and
-- should compose the frame using `blit` and `fill`. It runs with the back buffer
-- selected, so those calls are no-ops outside it rather than crashes.
--
-- @tparam ihandle widget widget whose area the overlay should cover
-- @tparam[opt] function draw frame composer `fn(overlay)`
-- @treturn boolean true when the overlay is up
-- @usage overlay:show(page, function(o) o:blit(snap, offset, 0) end)
function MotionOverlay:show(widget, draw)
	if not self:available() then return false end
	local x, y, w, h = self:rectOf(widget)
	if not x or w <= 0 or h <= 0 then return false end
	if not self:_ensureWindow() then return false end

	self._draw = draw
	self._rect = { x = x, y = y, w = w, h = h }

	-- Raised to the top of the Z-order on every show, NOT left where it was
	-- (SWP_NOZORDER). An overlay that is behind the window it is compositing over
	-- is invisible, and it fails exactly like an overlay that is not running at
	-- all: the animation ticks, the snapshots blit, and nothing appears on screen.
	-- SWP_NOACTIVATE is kept, so raising it never moves focus off the main dialog.
	local ok = pcall(function()
		user32.SetWindowPos(self._hwnd, HWND_TOP, x, y, w, h,
			bit.bor(SWP_NOACTIVATE, SWP_SHOWWINDOW))
	end)
	if not ok then return false end

	self._visible = true
	self:redraw()
	return true
end

--- Hide the overlay and drop its frame composer.
--
-- Hidden with the Win32 `ShowWindow`, NOT with IUP's `VISIBLE` attribute.
--
-- This window's placement, extended styles and visibility are all managed at the
-- Win32 level; `show()` puts it on screen with `SetWindowPos`. Setting IUP's
-- `VISIBLE` attribute to hide it mixes the two views of the same window -- IUP's
-- `IupHide` does its own bookkeeping on a dialog, and the raw `SetWindowPos` that
-- shows it again does not restore that bookkeeping. The next repaint then drew
-- through a canvas IUP believed was not on screen, and the process died with an
-- access violation on the second drag of a session.
--
-- Keeping both operations at the same level keeps the two views consistent.
--
-- @usage overlay:hide()
function MotionOverlay:hide()
	self._draw = nil
	if not self._visible then return end
	self._visible = false
	if self._hwnd ~= nil then
		pcall(function() user32.ShowWindow(self._hwnd, SW_HIDE) end)
	end
end

--- Is the overlay currently on screen?
-- @treturn boolean
function MotionOverlay:visible()
	return self._visible and true or false
end

--- Repaint immediately and synchronously.
--
-- `iup.Redraw` (not `iup.Update`) deliberately: `Update` only invalidates, leaving
-- the actual repaint to whenever the message queue next drains. An animation frame
-- computed now but painted at an arbitrary later time is exactly the jitter this
-- whole system exists to remove.
--
-- @usage overlay:redraw()
function MotionOverlay:redraw()
	if not self._visible or not self._canvas then return end
	pcall(self._iup.Redraw, self._canvas, 0)
end

--- Set whole-overlay opacity, 0..255.
-- Uses the layered window's alpha, so it costs nothing per pixel and composites
-- correctly against whatever lies beneath.
-- @tparam number alpha 0 (invisible) to 255 (opaque)
-- @usage overlay:setAlpha(128)
function MotionOverlay:setAlpha(alpha)
	if not self._hwnd then return end
	alpha = math.floor(math.max(0, math.min(255, tonumber(alpha) or 255)))
	pcall(function()
		user32.SetLayeredWindowAttributes(self._hwnd, 0, alpha, LWA_ALPHA)
	end)
end

--- The overlay's current size in pixels.
-- @treturn number w
-- @treturn number h
function MotionOverlay:size()
	return self._rect.w, self._rect.h
end

-- =======================================================================
-- SNAPSHOTS
-- =======================================================================

local function release_snapshot(snap)
	if snap.released then return end
	snap.released = true
	-- Drop the finaliser now that the handles are going explicitly, so the
	-- collector does not later run a finaliser that has nothing left to do.
	if snap.guard ~= nil then
		pcall(ffi.gc, snap.guard, nil)
		snap.guard = nil
	end
	if snap.old and snap.dc ~= nil then pcall(gdi32.SelectObject, snap.dc, snap.old) end
	if snap.bitmap ~= nil then pcall(gdi32.DeleteObject, snap.bitmap) end
	if snap.dc ~= nil then pcall(gdi32.DeleteDC, snap.dc) end
	snap.bitmap, snap.dc, snap.old = nil, nil, nil
end

--- Capture a widget's current pixels into an offscreen bitmap.
--
-- ### Captured from the dialog, not from the widget
--
-- The obvious implementation asks the widget for its own `HWND` and blits from
-- that. It does not work, and the way it fails is quiet: most IUP containers --
-- `vbox`, `hbox`, `zbox` -- are **layout constructs with no native window at all**.
-- A tab page is normally one of those, so `GetDC` returns nothing and every
-- capture comes back `nil`, which the callers dutifully treat as "no animation
-- available" rather than as a bug.
--
-- So the source is the **dialog's** device context, clipped to the widget's
-- rectangle. That works for any widget whether or not it owns a window, and it is
-- the more correct picture anyway: it captures the area as actually composited on
-- screen, with every child control already drawn into it.
--
-- `GetDC` returns a client-area DC whose origin is the client top-left, while
-- `SCREENPOSITION` is in screen coordinates -- hence the `ClientToScreen` call to
-- put both in the same space before subtracting.
--
-- `PrintWindow(PW_RENDERFULLCONTENT)` is the fallback for the case where BitBlt
-- comes back empty because the window renders only on `WM_PRINT`.
--
-- The returned snapshot **must** be released with `snap:release()` once the
-- animation ends. An `ffi.gc` finaliser is attached as a backstop so a forgotten
-- release cannot leak GDI objects, but relying on the collector holds a scarce
-- process-wide handle for an unbounded time -- release explicitly.
--
-- @tparam ihandle widget widget whose on-screen area should be captured
-- @treturn table|nil snapshot with `w`, `h` and `release()`, or `nil` on failure
-- @treturn string|nil reason, when the capture failed
-- @usage
--   local snap, why = overlay:capture(page)
--   if not snap then log("capture failed: " .. tostring(why)) end
function MotionOverlay:capture(widget)
	if not self:available() then return nil, "overlay unavailable" end
	if not widget then return nil, "no widget" end

	local wx, wy, w, h = self:rectOf(widget)
	if not wx then return nil, "no screen rectangle for widget" end
	if w <= 0 or h <= 0 then return nil, "degenerate size " .. w .. "x" .. h end

	local source = self._dialog or widget
	local hwnd = self:_hwndOf(source)
	if hwnd == nil then return nil, "no HWND on the source dialog" end

	local originx, originy = self:_clientOrigin(source)
	if not originx then return nil, "ClientToScreen failed" end
	local ox = wx - originx
	local oy = wy - originy

	local src_dc = user32.GetDC(hwnd)
	if src_dc == nil then return nil, "GetDC failed" end

	local snap = { w = w, h = h, released = false }
	local ok, err = pcall(function()
		snap.dc = gdi32.CreateCompatibleDC(src_dc)
		if snap.dc == nil then error("CreateCompatibleDC failed", 0) end
		snap.bitmap = gdi32.CreateCompatibleBitmap(src_dc, w, h)
		if snap.bitmap == nil then error("CreateCompatibleBitmap failed", 0) end
		snap.old = gdi32.SelectObject(snap.dc, snap.bitmap)

		if gdi32.BitBlt(snap.dc, 0, 0, w, h, src_dc, ox, oy, SRCCOPY) == 0 then
			-- Windows that paint only on WM_PRINT come back blank from BitBlt.
			if user32.PrintWindow(hwnd, snap.dc, PW_RENDERFULLCONTENT) == 0 then
				error("both BitBlt and PrintWindow failed", 0)
			end
		end
	end)

	pcall(user32.ReleaseDC, hwnd, src_dc)

	if not ok then
		release_snapshot(snap)
		return nil, tostring(err)
	end

	function snap:release() release_snapshot(self) end
	-- Backstop only; callers still release explicitly, because waiting for a GC
	-- cycle holds a scarce process-wide handle for an unbounded time.
	--
	-- The reference cycle here (snap -> guard -> closure -> snap) is deliberate and
	-- safe: LuaJIT finalises cdata the way Lua finalises `__gc` objects, collecting
	-- the cycle as a unit, so the finaliser does run. (Verified on the toolchain
	-- LuaJIT 2.1 -- this is NOT the weak-table trap where a value referencing its
	-- own key pins the entry forever.) `release_snapshot` unregisters the finaliser
	-- on the explicit path, so the backstop only ever fires for a genuinely
	-- dropped snapshot.
	snap.guard = ffi.gc(ffi.new("int[1]"), function() release_snapshot(snap) end)
	return snap
end

-- =======================================================================
-- FRAME COMPOSITION (valid only inside the `draw` callback)
-- =======================================================================

--- Blit a snapshot onto the frame at `x, y`.
--
-- `sw`/`sh` clip the copied region, which is what lets a sliding pane show only
-- the part of itself currently on screen.
--
-- @tparam table snap snapshot from `capture()`
-- @tparam number x destination X within the overlay
-- @tparam number y destination Y within the overlay
-- @tparam[opt] number sw source width (defaults to the full snapshot)
-- @tparam[opt] number sh source height
-- @tparam[opt=0] number sx source X offset
-- @tparam[opt=0] number sy source Y offset
-- @treturn boolean success
function MotionOverlay:blit(snap, x, y, sw, sh, sx, sy)
	if not snap or snap.released or self._target == nil then return false end
	return pcall(function()
		gdi32.BitBlt(self._target,
			math.floor(x), math.floor(y),
			math.floor(sw or snap.w), math.floor(sh or snap.h),
			snap.dc, math.floor(sx or 0), math.floor(sy or 0), SRCCOPY)
	end)
end

--- Is per-snapshot alpha blending available in this process?
--
-- `blendBlit` already falls back on its own, so callers do not need to check.
-- Exposed for the diagnostics harness, which reports it explicitly rather than
-- leaving "the cross-fade looks like a cut on this machine" to be puzzled over.
--
-- @treturn boolean
function MotionOverlay.static.blendSupported()
	return blend_ready
end

--- Blit a snapshot onto the frame at `x, y` with uniform transparency.
--
-- The compositing half of a cross-fade: `alpha` 0 draws nothing, 255 is identical
-- to `blit`. Snapshots are opaque device bitmaps with no per-pixel alpha channel,
-- so this uses `SourceConstantAlpha` and leaves `AlphaFormat` at zero -- asking
-- GDI to read a channel that is not there produces a black rectangle rather than
-- an error, which is a memorable way to lose an afternoon.
--
-- Falls back to an opaque `blit` when msimg32 is unavailable, and skips the draw
-- entirely at alpha 0. A cross-fade therefore degrades to a hard cut rather than
-- to nothing.
--
-- @tparam table snap snapshot from `capture()`
-- @tparam number x destination X within the overlay
-- @tparam number y destination Y within the overlay
-- @tparam[opt=255] number alpha 0 (invisible) to 255 (opaque)
-- @tparam[opt] number sw source width (defaults to the full snapshot)
-- @tparam[opt] number sh source height
-- @tparam[opt=0] number sx source X offset
-- @tparam[opt=0] number sy source Y offset
-- @treturn boolean success
-- @usage o:blendBlit(incoming, x, 0, 255 * progress)
function MotionOverlay:blendBlit(snap, x, y, alpha, sw, sh, sx, sy)
	if not snap or snap.released or self._target == nil then return false end

	alpha = math.floor(math.max(0, math.min(255, tonumber(alpha) or 255)))
	if alpha <= 0 then return true end
	if alpha >= 255 or not blend_ready then
		return self:blit(snap, x, y, sw, sh, sx, sy)
	end

	local w = math.floor(sw or snap.w)
	local h = math.floor(sh or snap.h)
	if w <= 0 or h <= 0 then return false end

	-- Source offsets exist so callers can blend only the part of a snapshot that
	-- is actually on the canvas. `AlphaBlend` is a software path in GDI, so its
	-- cost is proportional to the pixel count -- blending a full page when a
	-- third of it is off-screen is the single most expensive thing this module
	-- can be asked to do.
	sx = math.floor(sx or 0)
	sy = math.floor(sy or 0)

	-- Reused across frames: this runs up to 60 times a second, and a fresh cdata
	-- struct per frame is exactly the kind of allocation churn the rest of the
	-- motion system goes out of its way to avoid.
	local bf = self._blendfn
	if bf == nil then
		bf = ffi.new("LUNAR_BLENDFUNCTION")
		bf.BlendOp     = AC_SRC_OVER
		bf.BlendFlags  = 0
		bf.AlphaFormat = 0
		self._blendfn  = bf
	end
	bf.SourceConstantAlpha = alpha

	return pcall(function()
		-- Source and destination extents are equal: this never scales, so a
		-- clipped region lands pixel-for-pixel where it would have anyway.
		msimg32.AlphaBlend(self._target, math.floor(x), math.floor(y), w, h,
			snap.dc, sx, sy, w, h, bf)
	end)
end

--- Fill a rectangle on the frame with a `"R G B"` (or `"#RRGGBB"`) color.
-- @tparam number x
-- @tparam number y
-- @tparam number w
-- @tparam number h
-- @tparam string color `"R G B"` or `"#RRGGBB"`
-- @treturn boolean success
function MotionOverlay:fill(x, y, w, h, color)
	if self._target == nil then return false end
	if w <= 0 or h <= 0 then return false end
	local brush = self:_brush(colorref(color))
	if brush == nil then return false end

	local r = ffi.new("LUNAR_RECT[1]")
	r[0].left   = math.floor(x)
	r[0].top    = math.floor(y)
	r[0].right  = math.floor(x + w)
	r[0].bottom = math.floor(y + h)
	return pcall(function() user32.FillRect(self._target, r, brush) end)
end

--- Draw a rectangle outline on the frame.
-- @tparam number x
-- @tparam number y
-- @tparam number w
-- @tparam number h
-- @tparam string color `"R G B"` or `"#RRGGBB"`
-- @tparam[opt=1] number thickness outline thickness in pixels
function MotionOverlay:outline(x, y, w, h, color, thickness)
	thickness = math.max(1, math.floor(tonumber(thickness) or 1))
	if w <= 0 or h <= 0 then return end
	self:fill(x, y, w, thickness, color)
	self:fill(x, y + h - thickness, w, thickness, color)
	self:fill(x, y, thickness, h, color)
	self:fill(x + w - thickness, y, thickness, h, color)
end

--- Fill the whole frame with a single color.
-- @tparam string color `"R G B"` or `"#RRGGBB"`
function MotionOverlay:clear(color)
	self:fill(0, 0, self._rect.w, self._rect.h, color)
end

--- Destroy the overlay window and release every native resource it holds.
-- @usage overlay:destroy()
function MotionOverlay:destroy()
	self:hide()
	self:_releaseBack()
	for _, brush in pairs(self._brushes) do
		if brush ~= nil then pcall(gdi32.DeleteObject, brush) end
	end
	self._brushes = {}
	if self._dlg then
		pcall(self._iup.Destroy, self._dlg)
	end
	self._dlg, self._canvas, self._hwnd = nil, nil, nil
end

return MotionOverlay
