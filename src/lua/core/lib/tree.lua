--- Move widgets between (and within) containers without rebuilding them.
--
-- ### Why this is not just IupDetach + IupAppend
--
-- `IupDetach` opens with `IupUnmap` (`iup_childtree.c`), and `IupUnmap` **destroys
-- the native window of the widget and of everything under it**. Re-attaching then
-- calls `IupMap`, which builds that whole subtree again from nothing: new HWNDs,
-- re-applied attributes, re-created fonts and images, a fresh first paint.
--
-- For a status-bar icon that is a flash. For an extension's tab page -- a tree of
-- hundreds of controls -- it is a complete teardown and rebuild of every window on
-- that page, and it is why dragging a tab to a new position appeared to refresh
-- the entire app: nothing about the *content* changed, but every pixel of it was
-- thrown away and redrawn.
--
-- `IupReparent` exists for exactly this case. It performs the same Lua-side tree
-- surgery and fires the same `ChildRemoved`/`ChildAdded` class methods the detach
-- path does -- so `IupFlatTabs` still shuffles its position-indexed `TABTITLE`
-- attributes and still picks a new current tab -- but tells the native system with
-- a single `SetParent`. No unmap, no remap, no rebuilt windows. Reordering inside
-- one parent is cheaper still: `iupdrvReparent` compares the old and new parent
-- HWNDs and skips the `SetParent` entirely, leaving a pure list reorder that the
-- next layout pass turns into a `SetWindowPos`.
--
-- ### Why it still falls back
--
-- `IupReparent` returns `IUP_ERROR` in four cases, and only one of them is a real
-- refusal worth reacting to:
--
--   * the widget is already exactly where it is being asked to go -- a no-op, and
--     success as far as callers here are concerned;
--   * one of the two is mapped and the other is not. Normal during startup, when
--     the tree is assembled before `IupShow`;
--   * the destination would become its own descendant, or its child type forbids
--     another child.
--
-- Since only the *tree* can distinguish "declined" from "already done", a refusal
-- is checked against the tree rather than trusted. If the widget is in place there
-- is nothing left to do; otherwise the detach/attach path runs exactly as before.
--
-- @module core.lib.tree

local handle = require("core.lib.handle")

local M = {}

--- Position (0-based) of `widget` among `parent`'s children, or `nil`.
--
-- Compares through `core.lib.handle`, never with `==`: the binding mints a fresh
-- userdata per push, so a raw comparison never matches.
--
-- @tparam table iup the IUP binding
-- @tparam userdata parent the container to scan
-- @tparam userdata widget the child to find
-- @treturn number|nil 0-based position
function M.indexOf(iup, parent, widget)
	if not (iup and parent and widget) then return nil end
	local i = 0
	while true do
		local ok, child = pcall(iup.GetChild, parent, i)
		if not ok or not child then return nil end
		if handle.same(iup, child, widget) then return i end
		i = i + 1
	end
end

-- Is `widget` already the child of `parent` sitting immediately before `ref` (or
-- already the last child, when `ref` is nil)? That is the placement `place` below
-- is asked for, so this is what "nothing to do" means.
local function inPlace(iup, parent, widget, ref)
	local at = M.indexOf(iup, parent, widget)
	if at == nil then return false end
	if ref == nil then
		local ok, after = pcall(iup.GetChild, parent, at + 1)
		return not (ok and after)
	end
	local want = M.indexOf(iup, parent, ref)
	return want ~= nil and want == at + 1
end

--- Put `widget` into `parent`, immediately before `ref`.
--
-- `ref` must be a current child of `parent`; pass `nil` to append. Matches
-- `IupInsert`/`IupReparent`, where the reference child is the one the moved widget
-- lands *in front of*.
--
-- @tparam table iup the IUP binding
-- @tparam userdata parent the destination container
-- @tparam userdata widget the widget to move
-- @tparam[opt] userdata ref insert before this child; appends when omitted
-- @treturn boolean `true` when the widget kept its native window, `false` when it
--   was detached and re-attached and therefore needs mapping again
-- @usage
--   if not tree.place(iup, strip, page, kids[3]) then iup.Map(page) end
function M.place(iup, parent, widget, ref)
	if not (iup and parent and widget) then return false end

	-- Only an already-attached widget can be reparented: IupReparent detaches from
	-- the old parent first and walks that parent's child list to do it, so a
	-- parentless widget dereferences a null parent inside IUP rather than returning
	-- an error.
	local ok_parent, current = pcall(iup.GetParent, widget)
	local attached = ok_parent and current ~= nil

	if attached and type(iup.Reparent) == "function" then
		if inPlace(iup, parent, widget, ref) then return true end
		local ok, result = pcall(iup.Reparent, widget, parent, ref)
		-- IUP_NOERROR is 0. On anything else the tree is the only trustworthy
		-- report of whether the move happened -- see the module notes.
		if ok and (tonumber(result) == 0 or inPlace(iup, parent, widget, ref)) then
			return true
		end
	end

	pcall(iup.Detach, widget)
	if ref then
		pcall(iup.Insert, parent, ref, widget)
	else
		pcall(iup.Append, parent, widget)
	end
	return false
end

return M
