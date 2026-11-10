--- IupSplit on the ImGui host: a port of iup_split.c with Lunar's patches (patch 0008:
-- the sash stops where a side runs out of room, content1/content2; patch 0005: SASH grip,
-- HLCOLOR; the VISIBLE and BARSIZE rules that keep the bar off hidden tabs).
--
-- The first child is the internal bar, an IupFlatSeparator. Layout follows the C:
-- iSplitComputeNaturalSizeMethod sums the children along the split plus the bar and turns
-- VALUE=-1 into the first child's share; iSplitSetChildrenCurrentSizeMethod gives the
-- first child ceil(total * VALUE / 1000), cropped to what each side cannot give up, and
-- each child takes its current size by iupBaseSetCurrentSize (so a child that does not
-- expand keeps its natural size, as in IUP).
--
-- @module core.imgui.widgets.split
local Classes = require("core.imgui.Classes")
local Element = require("core.imgui.Element")
local Layout = require("core.imgui.Layout")
local bit = require("bit")
require("core.imgui.widgets.flatseparator")

local M = {}

local STATE = Element.STATE
local floor, ceil, max = math.floor, math.ceil, math.max

local ISPLIT_VERT, ISPLIT_HORIZ = "VERTICAL", "HORIZONTAL"

local bool = Element.isTrue -- iupStrBoolean

--- The control data, with iSplitCreateMethod's values. Attributes given to the
-- constructor arrive before `create` here, so the data starts on first use.
local function D(s)
	local d = s.data
	if d.val == nil then
		d.orientation = ISPLIT_VERT
		d.val = -1
		d.layoutdrag = true
		d.autohide = false
		d.barsize = 5
		d.showgrip = 1
		d.min, d.max = 0, 1000
		d.content1, d.content2 = 0, 0
	end
	return d
end

local function bar_of(s) local b = s.children[1]; return b and STATE[b] and STATE[b].internal and b or nil end
local function child1_of(s) return s.children[2] end
local function child2_of(s) return s.children[3] end
local function ignored(c) local cs = c and STATE[c]; return not cs or cs.attrs.FLOATING == "IGNORE" end

--- iSplitAutoHideChild
local function auto_hide_child(child, hide)
	if hide then
		if Element.getAttribute(child, "VISIBLE") ~= "NO" then
			Element.setAttribute(child, "FLOATING", "IGNORE")
			Element.setAttribute(child, "VISIBLE", "NO")
		end
	else
		if Element.getAttribute(child, "VISIBLE") == "NO" then
			Element.setAttribute(child, "FLOATING", "NO")
			Element.setAttribute(child, "VISIBLE", "YES")
		end
	end
end

--- iSplitAutoHide (the fork's tolerance: one bar's width, in thousandths)
local function auto_hide(s)
	local d = D(s)
	local child1 = child1_of(s)
	if not child1 then return end
	local child2 = child2_of(s)
	local size = (d.orientation == ISPLIT_VERT and s.w or s.h) or 0
	local tol
	if size <= d.barsize then tol = 50
	else tol = size > 0 and floor((1000 * d.barsize) / size) or 0 end
	auto_hide_child(child1, d.val <= tol)
	if child2 then auto_hide_child(child2, d.val >= 1000 - tol) end
end

--- iSplitAdjustVal
local function adjust_val(s)
	local d = D(s)
	if d.val < d.min then d.val = d.min end
	if d.val > d.max then d.val = d.max end
	if d.autohide then auto_hide(s) end
end

--- iSplitCropSize1 (patch 0008)
local function crop_size1(d, size1, total)
	if size1 > total - d.content2 then size1 = total - d.content2 end
	if size1 < d.content1 then size1 = d.content1 end
	return size1
end

--- iSplitUpdateContent
local function update_content(s)
	local d = D(s)
	local child1, child2 = child1_of(s), child2_of(s)
	local horizontal = d.orientation == ISPLIT_VERT
	d.content1 = child1 and Layout.minContent(child1, horizontal) or 0
	d.content2 = child2 and Layout.minContent(child2, horizontal) or 0
end

local function current(s) return D(s).orientation == ISPLIT_VERT and (s.w or 0) or (s.h or 0) end

--- iSplitGetWidth1 / iSplitGetHeight1: iupRoundUp, then the content crop
local function size1(s)
	local d = D(s)
	local total = current(s) - d.barsize
	local v = crop_size1(d, ceil((total * d.val) / 1000.0), total)
	if v < 0 then v = 0 end
	return v
end

--- iSplitGetWidth2 / iSplitGetHeight2
local function size2(s, s1)
	local v = (current(s) - D(s).barsize) - s1
	if v < 0 then v = 0 end
	return v
end

--- iSplitCalcVal (the fork's guard against nothing to divide)
local function calc_val(s, s1)
	local d = D(s)
	local total = current(s) - d.barsize
	if total <= 0 then return end
	d.val = floor((s1 * 1000) / total)
end

--- MINSIZE/MAXSIZE of a child along the split (iupLayoutApplyMinMaxSize on one axis)
local function minmax_along(child, v, vertical)
	local cs = STATE[child]
	local w, h = Layout.applyMinMax(cs, vertical and v or 0, vertical and 0 or v)
	return vertical and w or h
end

--- iSplitAdjustWidth1 / iSplitAdjustHeight1
local function adjust_size1(s, s1)
	local vertical = D(s).orientation == ISPLIT_VERT
	local child1 = child1_of(s)
	if child1 then
		local min1 = minmax_along(child1, s1, vertical)
		if min1 > s1 then return min1, true end
		local child2 = child2_of(s)
		if child2 then
			local s2 = size2(s, s1)
			local min2 = minmax_along(child2, s2, vertical)
			if min2 > s2 then
				return (current(s) - D(s).barsize) - min2, true
			end
		end
	end
	return s1, false
end

--- iSplitComputeNaturalSizeMethod
local function natural(e, s, L)
	local d = D(s)
	local vertical = d.orientation == ISPLIT_VERT
	local child1, child2 = child1_of(s), child2_of(s)
	local nw, nh = 0, 0
	local children_expand = 0
	if vertical then nw = nw + d.barsize else nh = nh + d.barsize end
	for _, child in ipairs({ child1 or false, child2 or false }) do
		if child and not ignored(child) then
			local cw, ch = L.natural(child)
			if vertical then nw, nh = nw + cw, max(nh, ch)
			else nw, nh = max(nw, cw), nh + ch end
			children_expand = bit.bor(children_expand, L.expandBits(child))
		end
	end
	if d.val == -1 then -- first time or reset, re-compute value from natural size
		if child1 then
			local cw, ch = L.natural(child1)
			local total = vertical and (nw - d.barsize) or (nh - d.barsize)
			d.val = total ~= 0 and floor(((vertical and cw or ch) * 1000) / total) or d.min
		else
			d.val = d.min
		end
		adjust_val(s)
	end
	return nw, nh, children_expand
end

--- iSplitSetChildrenCurrentSizeMethod + iSplitSetChildrenPositionMethod
local function place(e, s, L)
	local d = D(s)
	local old_val = d.val
	local vertical = d.orientation == ISPLIT_VERT
	local child1, child2 = child1_of(s), child2_of(s)
	local across = vertical and s.h or s.w
	local function offer(child, along)
		if vertical then return L.currentSize(child, along, across) end
		local cw, ch = L.currentSize(child, across, along)
		return ch, cw
	end

	update_content(s)
	local s1 = size1(s)
	local adjusted
	s1, adjusted = adjust_size1(s, s1)
	if adjusted then calc_val(s, s1) end -- has a MINMAX size, must fix split value

	local offered1, offered2 = s1, nil
	if child1 and not ignored(child1) then
		local c1 = offer(child1, s1)
		if c1 > s1 then -- has a minimum size, must fix split value
			s1 = c1
			calc_val(s, s1)
		end
	end
	if child2 and not ignored(child2) then
		local s2 = max(size2(s, s1), d.content2)
		offered2 = s2
		local c2 = offer(child2, s2)
		if c2 > s2 then -- has a minimum size, must fix split value
			s2 = c2
			offered2 = s2
			s1 = (current(s) - d.barsize) - s2
			calc_val(s, s1)
			offered1 = s1
		end
	end

	-- positions: the bar sits at GetWidth1 of the value as it is now
	local x, y = s.x, s.y
	local function put(child, at, along)
		if vertical then L.place(child, at, y, along, across)
		else L.place(child, x, at, across, along) end
	end
	if child1 and not ignored(child1) then put(child1, vertical and x or y, offered1) end
	local bar_at = (vertical and x or y) + size1(s)
	local bar = bar_of(s)
	if bar then
		if vertical then L.set(bar, bar_at, y, d.barsize, s.h) else L.set(bar, x, bar_at, s.w, d.barsize) end
	end
	if child2 and not ignored(child2) then put(child2, bar_at + d.barsize, offered2) end

	if old_val ~= d.val then Element.call(e, "VALUECHANGED_CB") end
end

-- The bar's mouse handling (iSplitButton_CB / iSplitMotion_CB), positions in dialog
-- coordinates where the C reads CURSORPOS: only their differences matter.
local function set_sash_hot(bar, hot)
	local s = STATE[STATE[bar].parent]
	if not s or D(s).showgrip ~= 3 then return end
	STATE[bar].attrs._IUPSASH_HOT = hot and "1" or nil
end

function M.barButton(bar, pressed, ex, ey, rt)
	local bs = STATE[bar]
	local e = bs.parent
	local s = STATE[e]
	local d = D(s)
	if not d.is_holding and pressed then -- DRAG BEGIN
		d.is_holding = true
		bs.attrs._IUPSASH_HELD = "1"
		if d.orientation == ISPLIT_VERT then
			d.start_pos, d.start_size = ex, bs.x - s.x
		else
			d.start_pos, d.start_size = ey, bs.y - s.y
		end
		if rt and rt.capture then rt.capture(bar) end
	elseif d.is_holding and not pressed then -- DRAG END
		d.is_holding = false
		bs.attrs._IUPSASH_HELD = nil
		set_sash_hot(bar, false)
		if rt and rt.release then rt.release() end
		if rt and rt.relayout then rt.relayout(e) end -- always refresh when releasing the mouse
	end
end

function M.barMotion(bar, ex, ey, button1, rt)
	local bs = STATE[bar]
	local e = bs.parent
	local s = STATE[e]
	local d = D(s)
	if not d.is_holding then return end
	if not button1 then d.is_holding = false; return end
	local old_val = d.val
	local pos = d.orientation == ISPLIT_VERT and ex or ey
	local s1 = adjust_size1(s, d.start_size + (pos - d.start_pos))
	calc_val(s, s1)
	adjust_val(s)
	if old_val ~= d.val then Element.call(e, "VALUECHANGED_CB") end
	if d.layoutdrag then
		if rt and rt.relayout then rt.relayout(e) end
	else
		-- iSplitSetBarPosition: only the bar moves
		if d.orientation == ISPLIT_VERT then bs.x = s.x + size1(s) else bs.y = s.y + size1(s) end
		Element.setAttribute(bar, "ZORDER", "TOP")
	end
end

function M.barEnter(bar) set_sash_hot(bar, true) end
function M.barLeave(bar)
	local s = STATE[STATE[bar].parent]
	-- the pointer outruns the bar while dragging: stay lit until release
	if not s or not D(s).is_holding then set_sash_hot(bar, false) end
end
function M.barFocus(bar, focus)
	local s = STATE[STATE[bar].parent]
	if s and not focus then D(s).is_holding = false end
end
function M.isHolding(e) local s = STATE[e]; return s and D(s).is_holding or false end

--- iSplitCreateMethod: the bar is the first child, an internal IupFlatSeparator
local function create(e, s)
	local d = D(s)
	local bar = Element.new("flatseparator", {})
	Element.appendInternal(e, bar, true)
	STATE[bar].data.split = e
	Element.setAttribute(bar, "EXPAND", "NO")
	Element.setAttribute(bar, "CURSOR", d.orientation == ISPLIT_VERT and "SPLITTER_VERT" or "SPLITTER_HORIZ")
	Element.setAttribute(bar, "STYLE", d.showgrip == 3 and "SASH" or d.showgrip == 2 and "DUALLINES" or d.showgrip == 1 and "GRIP" or
		(s.attrs.COLOR and "FILL" or "EMPTY"))
	Element.setAttribute(bar, "ORIENTATION", d.orientation)
	Element.setAttribute(bar, "BARSIZE", tostring(d.barsize))
	if d.barsize == 0 then Element.setAttribute(bar, "VISIBLE", "NO") end
	if d.pending_color then Element.setAttribute(bar, "COLOR", d.pending_color); d.pending_color = nil end
	if d.pending_hlcolor then Element.setAttribute(bar, "HLCOLOR", d.pending_hlcolor); d.pending_hlcolor = nil end
end

-- Attributes ---------------------------------------------------------------------------------

local function relayout(e)
	local ok, R = pcall(require, "core.imgui.Runtime")
	if ok and R.relayout then R.relayout(e) end
end

--- iSplitSetOrientationAttrib: only before map
local function set_orientation(e, s, value)
	if s.mapped then return false end
	local d = D(s)
	d.orientation = tostring(value or ""):upper() == "HORIZONTAL" and ISPLIT_HORIZ or ISPLIT_VERT
	local bar = bar_of(s)
	if bar then
		Element.setAttribute(bar, "ORIENTATION", value)
		Element.setAttribute(bar, "CURSOR", d.orientation == ISPLIT_VERT and "SPLITTER_VERT" or "SPLITTER_HORIZ")
	end
	return false
end

--- iSplitSetValueAttrib
local function set_value(e, s, value)
	local d = D(s)
	if value == nil then
		d.val = -1 -- reset to calculate in Natural size
	else
		local v = tonumber(value)
		if not v then return false end
		d.val = floor(v)
		adjust_val(s)
	end
	relayout(e)
	return false
end

--- iSplitSetBarSizeAttrib (the fork: the bar's VISIBLE only changes when crossing zero)
local function set_barsize(e, s, value)
	local d = D(s)
	local n = tonumber(value)
	if not n then return false end
	local old = d.barsize
	d.barsize = floor(n)
	local bar = bar_of(s)
	if bar then
		Element.setAttribute(bar, "BARSIZE", tostring(d.barsize))
		if d.barsize == 0 then
			Element.setAttribute(bar, "VISIBLE", "NO")
		elseif old == 0 then
			Element.setAttribute(bar, "VISIBLE", nil)
		end
	end
	if d.val ~= -1 then adjust_val(s) end -- because of autohide
	relayout(e)
	return false
end

--- iSplitSetMinMaxAttrib
local function set_minmax(e, s, value)
	local d = D(s)
	local a, b = tostring(value or ""):match("^%s*(-?%d+)%s*:%s*(-?%d+)")
	if not a then return false end
	a, b = tonumber(a), tonumber(b)
	if a > b then a, b = b, a end
	if a < 0 then a = 0 end
	if b > 1000 then b = 1000 end
	d.min, d.max = a, b
	if d.val ~= -1 then adjust_val(s) end
	relayout(e)
	return false
end

--- iSplitSetShowGripAttrib
local function set_showgrip(e, s, value)
	local d = D(s)
	local bar = bar_of(s)
	local v = tostring(value or ""):upper()
	local style
	if v == "SASH" then d.showgrip, style = 3, "SASH"
	elseif bool(v) then d.showgrip, style = 1, "GRIP"
	elseif v == "LINES" then d.showgrip, style = 2, "DUALLINES"
	else
		style = s.attrs.COLOR ~= nil and "FILL" or "EMPTY"
		d.showgrip = 0
		if d.barsize == 5 then set_barsize(e, s, "3") end
	end
	if bar then Element.setAttribute(bar, "STYLE", style) end
	return false
end

--- iSplitSetAutoHideAttrib
local function set_autohide(e, s, value)
	local d = D(s)
	if bool(value) then
		d.autohide = true
	else
		local child1 = child1_of(s)
		if child1 then
			auto_hide_child(child1, false)
			local child2 = child2_of(s)
			if child2 then auto_hide_child(child2, false) end
		end
		d.autohide = false
	end
	if d.val ~= -1 then adjust_val(s) end
	relayout(e)
	return false
end

--- iSplitSetColorAttrib: COLOR lives on the bar
local function set_color(e, s, value)
	local d = D(s)
	local bar = bar_of(s)
	if not bar then d.pending_color = value; return false end
	if value ~= nil and d.showgrip == 0 then Element.setAttribute(bar, "STYLE", "FILL") end
	Element.setAttribute(bar, "COLOR", value)
	return false
end

local function set_hlcolor(e, s, value)
	local bar = bar_of(s)
	if not bar then D(s).pending_hlcolor = value; return false end
	Element.setAttribute(bar, "HLCOLOR", value)
	return false
end

--- iSplitSetVisibleAttrib (the fork): the bar never stores its own VISIBLE while it has a size
local function set_visible(e, s, value)
	local bar = bar_of(s)
	if bar and D(s).barsize ~= 0 then STATE[bar].attrs.VISIBLE = nil end
	return true
end

--- IupSplit takes the bar and two children (IUP_CHILDMANY+3).
local function child_added(e, s, child)
	if #Element.userChildren(e) > 2 then Element.detach(child) end
end

Classes.define({
	name = "split", children = -1, focusable = false, type = "void", -- IUP_TYPEVOID
	-- iupLayoutMinContent: a VERTICAL split stacks its children across
	stacksAlong = function(e, s, horizontal) return (D(s).orientation == ISPLIT_VERT) == (horizontal and true or false) end,
	create = create, childAdded = child_added,
	natural = natural, place = place,
	set = {
		ORIENTATION = set_orientation, DIRECTION = set_orientation, VALUE = set_value,
		MINMAX = set_minmax, BARSIZE = set_barsize, SHOWGRIP = set_showgrip,
		AUTOHIDE = set_autohide, COLOR = set_color, HLCOLOR = set_hlcolor, VISIBLE = set_visible,
		LAYOUTDRAG = function(e, s, v) D(s).layoutdrag = bool(v); return false end,
	},
	get = {
		VALUE = function(e, s) return tostring(D(s).val) end,
		MINMAX = function(e, s) local d = D(s); return d.min .. ":" .. d.max end,
		BARSIZE = function(e, s) return tostring(D(s).barsize) end,
		-- the fork's getter: the registered default said VERTICAL whatever the split was
		ORIENTATION = function(e, s) return D(s).orientation end,
		LAYOUTDRAG = function(e, s) return D(s).layoutdrag and "YES" or "NO" end,
		AUTOHIDE = function(e, s) return D(s).autohide and "YES" or "NO" end,
		SHOWGRIP = function(e, s)
			local g = D(s).showgrip
			if g == 3 then return "SASH" elseif g == 2 then return "LINES" end
			return g ~= 0 and "YES" or "NO"
		end,
		COLOR = function(e, s) local bar = bar_of(s); return bar and Element.getAttribute(bar, "COLOR") end,
		HLCOLOR = function(e, s) local bar = bar_of(s); return bar and Element.getAttribute(bar, "HLCOLOR") end,
		--- iSplitGetClientSizeAttrib
		CLIENTSIZE = function(e, s)
			local d = D(s)
			local w, h = s.w or 0, s.h or 0
			if d.orientation == ISPLIT_VERT then w = w - d.barsize else h = h - d.barsize end
			return max(w, 0) .. "x" .. max(h, 0)
		end,
	},
	callbacks = { VALUECHANGED_CB = true },
})

return M
