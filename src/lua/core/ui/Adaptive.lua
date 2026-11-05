--- Pages that fit the pane they are in.
--
-- A tool page can land in a split pane a third of the window wide, so its layout has to
-- answer to the pane's width, not the screen's. Below `NARROW` a rail and its work area stack
-- instead of clipping. Report the width with `ctx:fitPage(panel, fit)`.
--
-- @module core.ui.Adaptive
local M = {}

local L = require("core.lib.CarbonLayout")
local Kit = require("core.ui.Kit")
local tree = require("core.lib.tree")

M.NARROW = 720
M.MEDIUM = 1100

--- `L.railPage` that stacks when the pane is narrow.
-- @tparam userdata iup
-- @tparam table opts `side`, `main`, `width`, as `L.railPage`, and `side_expand`: how the side
--   column fills a stack, default "HORIZONTAL" (its natural height)
-- @treturn ihandle the page
-- @treturn function `fit(width)`
function M.railPage(iup, opts)
	local row = L.railPage(iup, opts)
	local side, main = iup.GetChild(row, 0), iup.GetChild(row, 1)
	local strut = iup.GetChild(side, 0)
	local width = opts.width or L.SIDE.narrow
	local page = iup.vbox({ row, GAP = L.gap(5), EXPAND = "YES", MARGIN = "0x0" })
	local stacked = false

	local function fit(pane_width)
		local want = pane_width < M.NARROW
		if want == stacked then return end
		stacked = want
		if want then
			tree.place(iup, page, side, row)
			tree.place(iup, page, main, row)
			Kit.show(iup, row, false)
			iup.SetAttribute(strut, "RASTERSIZE", L.size(1))
			iup.SetAttribute(side, "EXPAND", opts.side_expand or "HORIZONTAL")
		else
			tree.place(iup, row, side)
			tree.place(iup, row, main)
			Kit.show(iup, row, true, side)
			iup.SetAttribute(strut, "RASTERSIZE", L.size(width))
			iup.SetAttribute(side, "EXPAND", "VERTICAL")
		end
		iup.Refresh(page)
	end
	return page, fit
end

--- Two to five joined options, one chosen, that fill the row.
-- @tparam userdata iup
-- @tparam table opts `labels`, `value_pos` (0 based), `on_change` `fn(position)`, 0 based
-- @return the control; `VALUEPOS` chooses, and `SetAttributeId(w, "TITLE", i, text)` relabels
function M.segmented(iup, opts)
	local widget = Kit.segmented(iup, opts)
	iup.SetAttribute(widget, "EXPAND", "HORIZONTAL")
	return widget
end

--- Show or hide the second pane of a split; its room goes to the first while hidden.
-- Not IupSplit's AUTOHIDE: that stores VISIBLE=YES on the panes, which then show through
-- whichever tab is in front. The split needs a MINMAX that reaches 1000.
-- @tparam userdata iup
-- @param split
-- @param second the split's second child
-- @tparam boolean open
-- @tparam number value where the sash sits while open, per mille
-- @param[opt] anchor see `Kit.show`
function M.setSecondPane(iup, split, second, open, value, anchor)
	Kit.show(iup, second, open, anchor)
	Kit.show(iup, iup.GetChild(split, 0), open, anchor) -- the sash
	iup.SetAttribute(split, "VALUE", tostring(open and value or 1000))
	iup.Refresh(split)
end

return M
