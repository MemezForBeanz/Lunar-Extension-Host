--- IUP's layout, in Lua, for the ImGui host's element tree.
--
-- A port of `iupLayoutCompute` (iup_layout.c, iup_classbase.c) with Lunar's patch
-- series applied, in IUP's three passes:
--
-- 1. Natural size, bottom-up (`iupBaseComputeNaturalSize`): the user size (SIZE or
--    RASTERSIZE, the one set last) wins for a control in each dimension it sets; a
--    container takes the larger of its user size and what its children need. EXPAND is
--    combined on the way up: a container only expands where its own EXPAND (default
--    YES, inherited from enclosing containers) and some child allow it.
-- 2. Current size, top-down (`iupBaseSetCurrentSize`): an element that expands in a
--    direction takes the size its parent offers there, otherwise its natural size;
--    without SHRINK a container never goes below its natural size.
-- 3. Position, top-down, in dialog client coordinates.
--
-- Passes 2 and 3 happen together here (`L.place`), because a box positions a child
-- right after deciding its size, exactly as IUP's SetChildrenCurrentSize and
-- SetChildrenPosition do one after the other.
--
-- Lunar's patch 0008 is in `M.minContent` (iupLayoutMinContent) and in the boxes: a box
-- narrower than its content takes the difference back from its expanding children in
-- proportion to what each can spare.
--
-- @module core.imgui.Layout
local Element = require("core.imgui.Element")
local Fonts = require("core.imgui.Fonts")
local bit = require("bit")
local band, bor = bit.band, bit.bor

local M = {}

local STATE = Element.STATE
local floor, max, min = math.floor, math.max, math.min

-- iup_object.h
local H0, H1, W0, W1, HFREE, WFREE = 0x01, 0x02, 0x04, 0x08, 0x10, 0x20
local WIDTH, HEIGHT = bor(W1, W0), bor(H1, H0)
local BOTH = bor(WIDTH, HEIGHT)
M.EXPAND = { H0 = H0, H1 = H1, W0 = W0, W1 = W1, HFREE = HFREE, WFREE = WFREE, WIDTH = WIDTH, HEIGHT = HEIGHT, BOTH = BOTH }

local EXPAND_BITS = {
	YES = BOTH, HORIZONTAL = WIDTH, VERTICAL = HEIGHT,
	HORIZONTALFREE = WFREE, VERTICALFREE = HFREE, NO = 0,
}

local function parse_pair(value, sep)
	if not value then return nil, nil end
	local a, b = tostring(value):match("^%s*([^" .. sep .. "]*)" .. sep .. "(.*)$")
	if not a then return tonumber(value), nil end
	return tonumber(a), tonumber(b)
end
M.parsePair = parse_pair

local function size_pair(value) return parse_pair(value, "x") end

--- Is this a container in IUP's sense (childtype != CHILDNONE)?
local function is_container(st)
	return st.class.children ~= 0 or st.classname == "dialog"
end

local function floating(st)
	local f = st.attrs.FLOATING
	if f == "IGNORE" then return true, true end
	if f == "YES" or f == "ON" then return true, false end
	return false, false
end
M.floating = floating

local SCREEN_FRACTION = { FULL = 1, HALF = 1 / 2, THIRD = 1 / 3, QUARTER = 1 / 4, EIGHTH = 1 / 8 }

local function screen_size()
	local ok, R = pcall(require, "core.imgui.Runtime")
	local s = ok and R.getGlobal and R.getGlobal("SCREENSIZE")
	local w, h = size_pair(s)
	return w or 1920, h or 1040
end

--- The user size in pixels (iupBaseSetSizeAttrib / iupBaseSetRasterSizeAttrib).
local function user_size(el, st)
	local a = st.attrs
	local raster = a.RASTERSIZE or a.USERSIZE
	if raster then
		local w, h = size_pair(raster)
		return max(w or 0, 0), max(h or 0, 0)
	end
	local s = a.SIZE
	if s then
		local ws, hs = tostring(s):match("^%s*([^x]*)x?(.*)$")
		local cw, ch = Fonts.forElement(el):charsize()
		local w, h = 0, 0
		if st.classname == "dialog" and (SCREEN_FRACTION[ws] or SCREEN_FRACTION[hs]) then
			local sw, sh = screen_size()
			if SCREEN_FRACTION[ws] then w = floor(sw * SCREEN_FRACTION[ws]) end
			if SCREEN_FRACTION[hs] then h = floor(sh * SCREEN_FRACTION[hs]) end
		end
		local nw, nh = tonumber(ws), tonumber(hs)
		if nw then w = floor(nw * cw / 4) end      -- iupWIDTH2RASTER
		if nh then h = floor(nh * ch / 8) end      -- iupHEIGHT2RASTER
		return max(w, 0), max(h, 0)
	end
	return 0, 0
end
M.userSize = user_size

-- SIZE and RASTERSIZE replace each other: the one set last is the user size.
Element.commonSet.RASTERSIZE = function(el, st)
	if st.classname ~= "dialog" or not st.data.shown then st.attrs.SIZE = nil end
end
Element.commonSet.SIZE = function(el, st)
	st.attrs.RASTERSIZE = nil
	st.attrs.USERSIZE = nil
end

local function apply_minmax(st, w, h)
	local a = st.attrs
	if a.MINSIZE then
		local mw, mh = size_pair(a.MINSIZE)
		if mw and w < mw then w = mw end
		if mh and h < mh then h = mh end
	end
	if a.MAXSIZE then
		local xw, xh = size_pair(a.MAXSIZE)
		if xw and w > xw then w = xw end
		if xh and h > xh then h = xh end
	end
	return w, h
end
M.applyMinMax = apply_minmax

--- EXPAND of a container: its own, or the nearest enclosing element's (iupAttribGetInherit).
local function container_expand(st)
	local s = st
	while s do
		local v = s.attrs.EXPAND
		if v then return EXPAND_BITS[v:upper()] or BOTH end
		s = s.parent and STATE[s.parent]
	end
	return BOTH
end

local function control_expand(el, st)
	local v = st.attrs.EXPAND
	if v == nil then
		local d = st.class.expandDefault
		if type(d) == "function" then d = d(el, st) end
		v = d
	end
	if not v then return 0 end
	return EXPAND_BITS[tostring(v):upper()] or 0
end

-- The helper handed to class.natural / class.place --------------------------------------
local L = {}
M.L = L
L.EXPAND = M.EXPAND

function L.font(el) return Fonts.forElement(el) end
function L.charsize(el) return Fonts.forElement(el):charsize() end
function L.size(value) return size_pair(value) end

function L.natural(el)
	local st = STATE[el]
	if not st then return 0, 0 end
	return st.nat_w or 0, st.nat_h or 0
end

--- Expand flags of a computed child: (horizontal, vertical) booleans, and the raw bits.
function L.expand(el)
	local st = STATE[el]
	if not st then return false, false, 0 end
	local e = st.expand or 0
	return band(e, bor(WIDTH, WFREE)) ~= 0, band(e, bor(HEIGHT, HFREE)) ~= 0, e
end

function L.expandBits(el)
	local st = STATE[el]
	return st and st.expand or 0
end

--- Laid out by its parent? (not FLOATING; VISIBLE=NO still takes its space, as in IUP)
function L.visible(el)
	local st = STATE[el]
	if not st then return false end
	local f = floating(st)
	return not f
end

function L.floating(el)
	local st = STATE[el]
	if not st then return false, false end
	return floating(st)
end

local shrink_flag = false
function L.shrink() return shrink_flag end

--- iupBaseSetCurrentSize: the size an element takes when offered (w, h).
function L.currentSize(el, w, h)
	local st = STATE[el]
	if not st then return 0, 0 end
	local nw, nh = st.nat_w or 0, st.nat_h or 0
	if is_container(st) and not shrink_flag then
		w, h = max(nw, w), max(nh, h)
	end
	local e = st.expand or 0
	local ew = band(e, bor(WIDTH, WFREE)) ~= 0
	local eh = band(e, bor(HEIGHT, HFREE)) ~= 0
	local cw = ew and w or nw
	local ch = eh and h or nh
	if ew or eh then cw, ch = apply_minmax(st, cw, ch) end
	return max(0, floor(cw)), max(0, floor(ch))
end

--- Give a child the rect (x, y, w, h): it takes its current size by IUP's rule, sits at
-- (x, y), and lays out its own children.
function L.place(el, x, y, w, h)
	local st = STATE[el]
	if not st then return end
	local cw, ch = L.currentSize(el, w or 0, h or 0)
	st.x, st.y, st.w, st.h = floor(x + 0.5), floor(y + 0.5), cw, ch
	M.placeChildren(el, st)
end

--- Put a child exactly at (x, y, w, h), bypassing the expand rule (for containers
-- that size their children themselves, like a split's two panes).
function L.set(el, x, y, w, h)
	local st = STATE[el]
	if not st then return end
	st.x, st.y, st.w, st.h = floor(x + 0.5), floor(y + 0.5), max(0, floor(w)), max(0, floor(h))
	M.placeChildren(el, st)
end

function L.minContent(el, horizontal) return M.minContent(el, horizontal) end

-- Pass 1 -------------------------------------------------------------------------------

local function compute(el)
	local st = STATE[el]
	if not st then return 0, 0 end
	local class = st.class
	local uw, uh = user_size(el, st)
	local nw, nh = uw, uh

	if is_container(st) then
		local own = container_expand(st)
		if st.classname == "dialog" and not st.attrs.EXPAND then own = BOTH end
		-- children first (FLOATING=IGNORE ones are skipped entirely)
		local children_expand = 0
		for _, c in ipairs(st.children) do
			local cs = STATE[c]
			if cs then
				local f, ignore = floating(cs)
				if not ignore then compute(c) end
				if not f and not (class.childrenExpand) then children_expand = bor(children_expand, cs.expand or 0) end
			end
		end
		st.expand = own
		local w, h, ce = 0, 0, nil
		if class.natural then w, h, ce = class.natural(el, st, L) end
		if ce then children_expand = ce end
		if class.childrenExpand then children_expand = class.childrenExpand(el, st, L) or children_expand end
		w, h = floor(w or 0), floor(h or 0)
		if st.classname == "dialog" then
			st.expand = bor(own, children_expand)
			if nw <= 0 then nw = w end
			if nh <= 0 then nh = h end
		else
			st.expand = band(own, children_expand)
			nw, nh = max(nw, w), max(nh, h)
		end
	else
		st.expand = control_expand(el, st)
		if nw <= 0 or nh <= 0 then
			local w, h, e = 0, 0, nil
			if class.natural then w, h, e = class.natural(el, st, L) end
			if nw <= 0 then nw = floor(w or 0) end
			if nh <= 0 then nh = floor(h or 0) end
			if e then st.expand = e end
		end
		if class.expandOverride then
			local e = class.expandOverride(el, st, L)
			if e then st.expand = e end
		end
	end
	nw, nh = apply_minmax(st, nw, nh)
	st.nat_w, st.nat_h = nw, nh
	return nw, nh
end
M.compute = compute

-- Passes 2 and 3 ---------------------------------------------------------------------------

--- Lay out an element's children inside its (already set) rect.
function M.placeChildren(el, st)
	if #st.children == 0 then return end
	local class = st.class
	if class.place then
		class.place(el, st, L)
		return
	end
	-- Default: every child gets the whole rect (zbox-like), floating ones their natural size.
	for _, c in ipairs(st.children) do
		local cs = STATE[c]
		if cs then
			local f = floating(cs)
			if f then M.placeFloating(c, cs, st) else L.place(c, st.x, st.y, st.w, st.h) end
		end
	end
end

--- A FLOATING child keeps its natural size; POSITION ("x,y", relative to the parent)
-- says where it goes.
function M.placeFloating(el, st, parent_st)
	local px, py = parse_pair(st.attrs.POSITION, ",")
	st.w, st.h = st.nat_w or 0, st.nat_h or 0
	if px then
		st.x, st.y = parent_st.x + px, parent_st.y + (py or 0)
	else
		st.x, st.y = parent_st.x, parent_st.y
	end
	M.placeChildren(el, st)
end

--- iupLayoutMinContent (patch 0008): what a subtree cannot give up along one axis.
function M.minContent(el, horizontal)
	local st = STATE[el]
	if not st then return 0 end
	local natural = horizontal and (st.nat_w or 0) or (st.nat_h or 0)
	local e = st.expand or 0
	local expands = band(e, horizontal and bor(WIDTH, WFREE) or bor(HEIGHT, HFREE)) ~= 0
	if floating(st) then return 0 end
	if not expands then return natural end
	local name = st.classname
	if #st.children == 0 or name == "flattabs" or name == "tabs" or name == "flatscrollbox" or name == "scrollbox" then
		local w, h = apply_minmax(st, 0, 0)
		return horizontal and w or h
	end
	local along
	if name == "split" then
		along = ((Element.getAttribute(el, "ORIENTATION") or "VERTICAL"):upper() == "VERTICAL") == (horizontal and true or false)
	else
		along = name == (horizontal and "hbox" or "vbox")
	end
	local natural_kids, min_kids = 0, 0
	for _, c in ipairs(st.children) do
		local cs = STATE[c]
		if cs and not floating(cs) and not cs.class.internal then
			local cn = horizontal and (cs.nat_w or 0) or (cs.nat_h or 0)
			local cm = M.minContent(c, horizontal)
			if along then
				natural_kids = natural_kids + cn
				min_kids = min_kids + cm
			else
				natural_kids = max(natural_kids, cn)
				min_kids = max(min_kids, cm)
			end
		end
	end
	local margins = natural - natural_kids
	local w = min_kids + max(margins, 0)
	local mw, mh = apply_minmax(st, w, w)
	return horizontal and mw or mh
end

--- Lay out a dialog in a client area of (w, h).
function M.run(dialog, w, h)
	local st = STATE[dialog]
	if not st then return end
	shrink_flag = Element.getAttribute(dialog, "SHRINK") == "YES"
	compute(dialog)
	st.x, st.y = 0, 0
	st.w, st.h = floor(w or st.nat_w), floor(h or st.nat_h)
	M.placeChildren(dialog, st)
	return L
end

--- An element's natural size, computing its subtree.
function M.natural(el)
	return compute(el)
end

--- Lay out any subtree in a rect (used by tests and by overlays that host a tree).
function M.layout(el, x, y, w, h)
	compute(el)
	L.place(el, x, y, w, h)
end

return M
