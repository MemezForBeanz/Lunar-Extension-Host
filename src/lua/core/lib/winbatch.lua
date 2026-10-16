--- Atomic repaint batching for a burst of window moves.
--
-- ### The problem
--
-- IUP repositions a container's children one window at a time
-- (`iupdrvBaseLayoutUpdateMethod` is a single `SetWindowPos` per child). None of
-- those calls paint; they invalidate, and the resulting `WM_PAINT`s are
-- dispatched **individually** by the message loop afterwards. Each child
-- therefore appears at its new position at a slightly different moment, and on a
-- split drag -- where this happens continuously -- the panes visibly tear.
--
-- `WS_CLIPCHILDREN` (which IUP always sets on native parents) does not help: it
-- stops the parent painting over its children, and says nothing about children
-- painting at different times from each other.
--
-- ### The fix, and the detail that matters
--
-- Suppress painting on the parent, move everything, then force **one
-- synchronous** repaint of the whole subtree:
--
--     WM_SETREDRAW 0  ->  move children  ->  WM_SETREDRAW 1
--     RedrawWindow(RDW_INVALIDATE | RDW_ERASE | RDW_ALLCHILDREN | RDW_UPDATENOW)
--
-- `RDW_UPDATENOW` is the load-bearing flag and the reason an earlier version of
-- this module did not fix the tearing. Without it `RedrawWindow` only marks the
-- subtree dirty and returns; the paints are then delivered one per child by the
-- message loop -- precisely the behaviour being removed. With it, every child is
-- painted before `RedrawWindow` returns, so the subtree reaches the screen as a
-- single visual state.
--
-- IUP itself uses exactly this flag set for its own synchronous redraw
-- (`iupdrvRedrawNow`: `RDW_ERASE|RDW_INVALIDATE|RDW_INTERNALPAINT|RDW_UPDATENOW`).
--
-- ### Why not the alternatives
--
--   * `LockWindowUpdate` -- what `winredraw` uses -- is **process-global**, holds
--     one window system-wide, and is documented for drag-feedback rendering only.
--     Right for `ThemeManager`'s one-shot whole-dialog walk; wrong at drag rate.
--   * `WS_EX_COMPOSITED` (IUP's `COMPOSITED=YES`) double-buffers all children,
--     which would also solve this, but it is incompatible with `CS_OWNDC` windows
--     and IupCanvas uses `CS_OWNDC` -- every flat control in this application is
--     canvas-backed. `core.main` sets `COMPOSITED=NO` deliberately, having already
--     found it made tearing worse here.
--
-- ### The target is an ANCESTOR, not the widget itself
--
-- Most IUP containers own no window (`ic->nativetype = IUP_TYPEVOID`), and
-- `IupSplit` -- the caller this exists for -- is one of them. The target is
-- resolved by walking up to the nearest ancestor that does have an `HWND`, which
-- is the window whose children are actually moving.
--
-- ### Degradation
--
-- Without LuaJIT FFI, `iupraw`, or any native ancestor, `batch` still runs its
-- function, just unbatched. Callers never need to check `available`.
--
-- Not covered by the busted suite: `iupraw` and a real HWND exist only inside the
-- host executable, so `available` is always false under the test runner.
--
-- @module core.lib.winbatch

local M = { available = false }

local ok_ffi, ffi = pcall(require, "ffi")
if not ok_ffi then ffi = nil end

local ok_iupffi, IupFFI = pcall(require, "core.classes.IupFFI")
if not ok_iupffi then IupFFI = nil end

local user32

if ffi and IupFFI and IupFFI.available then
	-- cdef is per-Lua-state and raises on redeclaration. require caches this
	-- module so it normally runs once; pcall keeps a stray re-require harmless.
	pcall(ffi.cdef, [[
		long SendMessageA(void *hwnd, unsigned int msg, unsigned int wparam, long lparam);
		int  RedrawWindow(void *hwnd, const void *rect, void *rgn, unsigned int flags);
	]])

	local ok = pcall(function()
		user32 = ffi.load("user32")
		local _ = user32.SendMessageA
		local _ = user32.RedrawWindow
	end)

	M.available = ok and true or false
	if not ok then user32 = nil end
end

local WM_SETREDRAW = 0x000B

local RDW_INVALIDATE  = 0x0001
local RDW_ERASE       = 0x0004
local RDW_ALLCHILDREN = 0x0080
local RDW_UPDATENOW   = 0x0100

-- Ceiling on the ancestor walk. Deep enough for any real layout, shallow enough
-- that a cyclic parent chain cannot spin inside a mouse-move callback.
local MAX_ANCESTOR_WALK = 64

local function hwnd_of(iup, widget)
	if not (M.available and widget) then return nil end

	local node = widget
	for _ = 1, MAX_ANCESTOR_WALK do
		local ok, hwnd = pcall(function()
			local p = IupFFI.ptr(node)
			if p == nil then return nil end
			return IupFFI.getptr(p, "HWND")
		end)
		if ok and hwnd ~= nil then return hwnd end

		if not iup or not iup.GetParent then return nil end
		local ok_parent, parent = pcall(iup.GetParent, node)
		if not ok_parent or parent == nil then return nil end
		node = parent
	end
	return nil
end

--- Does `widget` (or an ancestor) own a native window this module can batch?
-- @tparam userdata iup the IUP binding, for the ancestor walk
-- @tparam ihandle widget
-- @treturn boolean
function M.batchable(iup, widget)
	return hwnd_of(iup, widget) ~= nil
end

-- Depth per HWND, so nested batches issue one suspend and one repaint. Keyed by
-- the pointer's string form: two cdata pointers to the same address are not
-- equal as table keys. Entries are removed as they unwind, so this cannot grow.
local depth = {}

--- Run `fn`, then repaint `widget`'s nearest native ancestor in one pass.
--
-- Re-entrant; nested calls join the outer batch rather than repainting early.
--
-- Exception-safe, which matters more than usual here: a window left with
-- `WM_SETREDRAW` off never paints again, so an error escaping this would freeze
-- part of the UI permanently. Redraws are always restored, then the error is
-- re-raised.
--
-- @tparam userdata iup the IUP binding
-- @tparam ihandle widget the widget whose layout is changing
-- @tparam function fn the layout work to perform
-- @return whatever `fn` returned
-- @usage winbatch.batch(iup, split, function() iup.RefreshChildren(split) end)
function M.batch(iup, widget, fn)
	if type(fn) ~= "function" then return end

	local hwnd = hwnd_of(iup, widget)
	if hwnd == nil then
		return fn()   -- nothing to batch against; the work still has to happen
	end

	local key = tostring(hwnd)
	local d = (depth[key] or 0) + 1
	depth[key] = d

	if d == 1 then
		pcall(function() user32.SendMessageA(hwnd, WM_SETREDRAW, 0, 0) end)
	end

	local ok, a, b = pcall(fn)

	if d > 1 then
		depth[key] = d - 1
	else
		depth[key] = nil
		-- Order matters: redraws must be back ON before the repaint is requested,
		-- or the RedrawWindow is discarded and the window stays blank.
		pcall(function() user32.SendMessageA(hwnd, WM_SETREDRAW, 1, 0) end)
		pcall(function()
			user32.RedrawWindow(hwnd, nil, nil,
				RDW_INVALIDATE + RDW_ERASE + RDW_ALLCHILDREN + RDW_UPDATENOW)
		end)
	end

	if not ok then error(a, 0) end
	return a, b
end

return M
