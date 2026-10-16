--- Smooth dragging for `iup.split` dividers.
--
-- Apply this to every split in the application. It is a small module with one
-- job: keep IUP's live-layout drag behaviour, minus the one call in it that
-- causes the tearing.
--
-- ### What IUP does by default, and why it tears
--
-- `IupSplit` defaults to `LAYOUTDRAG=YES`. Its motion callback
-- (`iup_split.c`, `iSplitMotion_CB`) then runs, **on every mouse-move sample**:
--
--     if (ih->data->layoutdrag) { IupRefreshChildren(ih); IupFlush(); }
--
-- `IupRefreshChildren` is not the problem. All it does is reposition the panes'
-- children with one `SetWindowPos` each (`iupLayoutUpdate` ->
-- `iupdrvBaseLayoutUpdateMethod`); none of those paint anything. They post
-- `WM_PAINT`, and Windows coalesces those into a single repaint once the message
-- loop next runs.
--
-- `IupFlush` is the problem. It drains the entire message queue synchronously,
-- from inside a mouse handler, dozens of times a second -- so those `WM_PAINT`s
-- are dispatched *while the relayout is still in progress*, and each child is
-- painted at its new position one at a time. That sequential repaint is the
-- tearing. It also starves everything else on the thread, including the
-- animation driver's frames, which arrive on the low-priority `WM_TIMER`.
--
-- ### What this does instead
--
-- `LAYOUTDRAG=NO` stops IUP relaying out and flushing; it then tracks the drag by
-- moving only the divider bar (`iSplitSetBarPosition`). We relayout the panes
-- ourselves from `VALUECHANGED_CB` -- on **every** sample, exactly as IUP did --
-- and never flush. Each relayout is wrapped in `core.lib.winbatch`, which
-- suppresses painting while the children move and then repaints the subtree in
-- one synchronous pass, so the panes reach the screen as a single visual state
-- instead of child by child.
--
-- ### Why the panes are not relaid out at a reduced rate
--
-- They were, briefly, at ~30 fps, on the theory that the divider bar tracks the
-- mouse at full rate anyway so the panes could lag behind it unnoticed. That was
-- wrong, and is worth recording: rationing the relayout does not read as a lower
-- frame rate, it reads as the panes JUMPING to catch up with a divider that is
-- already somewhere else. The content and the bar visibly disagree about where
-- the split is, which is a worse artefact than the tearing it was meant to fix.
--
-- Responsiveness and tearing are independent problems here, and each has its own
-- fix: relayout every sample for the first, batch the repaint for the second.
-- Trading one against the other -- which the throttle did -- solves neither.
--
-- ### Degradation
--
-- `LAYOUTDRAG=NO` is a plain attribute write; the callback falls back to
-- `iup.Refresh` on a binding without `iup.RefreshChildren`; and `winbatch`
-- passes the work straight through when FFI is unavailable. The drag always
-- works, with or without the smoothing.
--
-- @module core.lib.SplitMotion

local winbatch = require("core.lib.winbatch")

local M = {}

--- Attach smooth drag behaviour to a split.
--
-- `opts` fields:
--
--   * `on_change` -- optional `fn(split)` called after each relayout, for
--     callers that need to react to the new geometry
--
-- @tparam userdata iup the IUP binding
-- @tparam ihandle split the `iup.split` to attach to
-- @tparam[opt] table opts see above
-- @treturn ihandle `split`, for chaining
-- @usage SplitMotion.attach(iup, main_split)
function M.attach(iup, split, opts)
	if not (iup and split) then return split end
	opts = opts or {}

	-- The fix: stop IUP relaying out AND flushing on every mouse sample. From
	-- here it only moves the divider bar; the relayout below is ours.
	pcall(iup.SetAttribute, split, "LAYOUTDRAG", "NO")

	local on_change = opts.on_change

	function split:valuechanged_cb()
		-- `RefreshChildren`, never `Refresh`. The latter ignores the widget it is
		-- given and relays out the whole dialog, which on a drag would be an
		-- enormous amount of work per mouse sample.
		--
		-- Scoping to the split is correct here specifically because a drag
		-- changes the size of its CHILDREN, never of the split itself.
		-- `IupRefreshChildren` discards any change to the container's own size,
		-- so it is only ever right for a container that is not itself resizing --
		-- which is why `core.ui.SettingsView`, whose containers DO grow, cannot
		-- use it.
		--
		-- Batched so the children arrive on screen together. Unbatched, each one
		-- is painted by its own WM_PAINT at a slightly different moment, which is
		-- the tearing.
		local refresh = iup.RefreshChildren or iup.Refresh
		winbatch.batch(iup, split, function()
			pcall(refresh, split)
		end)

		if on_change then pcall(on_change, split) end
		return iup.DEFAULT
	end

	return split
end

return M
