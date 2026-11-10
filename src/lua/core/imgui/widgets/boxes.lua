--- IUP's layout containers on the ImGui host: hbox, vbox, zbox, fill, cbox, gridbox,
-- normalizer, backgroundbox, radio, sbox, user, frame.
--
-- Each is a port of its iup_<name>.c ComputeNaturalSize / SetChildrenCurrentSize /
-- SetChildrenPosition, with Lunar's patches: GAP and MARGIN are local (0005), and a box
-- narrower than its content takes the difference back from its expanding children in
-- proportion to what each can spare (0008).
--
-- `type` is IupGetClassType's answer, the class's nativetype: the boxes, the fill and the
-- normalizer are "void" (no native window: positions and the native parent pass through
-- them), IupUser is "other".
--
-- @module core.imgui.widgets.boxes
local Classes = require("core.imgui.Classes")
local Element = require("core.imgui.Element")
local Layout = require("core.imgui.Layout")
local bit = require("bit")
local band = bit.band

local M = {}

local STATE = Element.STATE
local floor, max, min = math.floor, math.max, math.min
local E = Layout.EXPAND

local function own(st, name) return st.attrs[name] end

--- MARGIN/CMARGIN (and N variants), in pixels: horizontal, vertical.
local function margins(el, st, L)
	local a = st.attrs
	local v = a.MARGIN or a.NMARGIN
	if v then
		local x, y = Layout.parsePair(v, "x")
		return x or 0, y or 0
	end
	v = a.CMARGIN or a.NCMARGIN
	if v then
		local x, y = Layout.parsePair(v, "x")
		local cw, ch = L.charsize(el)
		return floor((x or 0) * cw / 4), floor((y or 0) * ch / 8)
	end
	return 0, 0
end
M.margins = margins

local function gap(el, st, L, vertical)
	local a = st.attrs
	local v = a.GAP or a.NGAP
	if v then return tonumber(v) or 0 end
	v = a.CGAP or a.NCGAP
	if v then
		local cw, ch = L.charsize(el)
		return vertical and floor((tonumber(v) or 0) * ch / 8) or floor((tonumber(v) or 0) * cw / 4)
	end
	return 0
end

local NORMALIZE = { HORIZONTAL = 1, VERTICAL = 2, BOTH = 3 }

-- hbox / vbox ----------------------------------------------------------------------------

local function box_natural(vertical)
	return function(el, st, L)
		local d = st.data
		local mx, my = margins(el, st, L)
		local g = gap(el, st, L, vertical)
		d.mx, d.my, d.gap = mx, my, g
		local expand_children = own(st, "EXPANDCHILDREN")
		local ec = nil
		if expand_children and expand_children ~= "NO" then
			ec = expand_children == "YES" and E.BOTH or expand_children == "HORIZONTAL" and E.WIDTH
				or expand_children == "VERTICAL" and E.HEIGHT or nil
		end
		local count, maxw, maxh = 0, 0, 0
		local children_expand = 0
		for _, c in ipairs(st.children) do
			local cs = STATE[c]
			if cs then
				if ec then cs.expand = ec end
				if not Layout.floating(cs) then
					children_expand = bit.bor(children_expand, cs.expand or 0)
					maxw = max(maxw, cs.nat_w or 0)
					maxh = max(maxh, cs.nat_h or 0)
					count = count + 1
				end
			end
		end
		local norm = NORMALIZE[(own(st, "NORMALIZESIZE") or ""):upper()]
		if norm then
			for _, c in ipairs(st.children) do
				local cs = STATE[c]
				if cs and not Layout.floating(cs) and cs.classname ~= "fill" then
					if band(norm, 1) ~= 0 then cs.nat_w = maxw end
					if band(norm, 2) ~= 0 then cs.nat_h = maxh end
				end
			end
		end
		local along = 0
		for _, c in ipairs(st.children) do
			local cs = STATE[c]
			if cs and not Layout.floating(cs) then along = along + (vertical and cs.nat_h or cs.nat_w) end
		end
		local homogeneous = own(st, "HOMOGENEOUS") == "YES"
		d.homogeneous = homogeneous
		if homogeneous then along = (vertical and maxh or maxw) * count end
		local total_along = along + max(count - 1, 0) * g + 2 * (vertical and my or mx)
		local total_cross = (vertical and maxw or maxh) + 2 * (vertical and mx or my)
		d.total_natural = total_along
		if vertical then return total_cross, total_along, children_expand end
		return total_along, total_cross, children_expand
	end
end

local function alignment(st, vertical)
	local a = (own(st, "ALIGNMENT") or ""):upper()
	if vertical then
		if a == "ACENTER" then return 0.5 elseif a == "ARIGHT" then return 1 end
		return 0
	end
	if a == "ACENTER" then return 0.5 elseif a == "ABOTTOM" then return 1 end
	return 0
end

local function box_place(vertical)
	local ONE = vertical and E.H1 or E.W1
	local ZERO = vertical and E.H0 or E.W0
	return function(el, st, L)
		local d = st.data
		local mx, my, g = d.mx or 0, d.my or 0, d.gap or 0
		local current = vertical and st.h or st.w
		local items = {}
		for _, c in ipairs(st.children) do
			local cs = STATE[c]
			if cs then
				if Layout.floating(cs) then
					local _, ignore = Layout.floating(cs)
					if not ignore then Layout.placeFloating(c, cs, st) end
				else
					items[#items + 1] = c
				end
			end
		end
		local n = #items
		local homogeneous_size = 0
		local empty1, empty0, deficit, slack_total = 0, 0, 0, 0
		local total = d.total_natural or 0
		if d.homogeneous then
			if n > 0 then
				homogeneous_size = max(0, floor((current - (n - 1) * g - 2 * (vertical and my or mx)) / n))
			end
		else
			local e = st.expand or 0
			local function empty(flag)
				local count = 0
				for _, c in ipairs(items) do
					if band(STATE[c].expand or 0, flag) ~= 0 then count = count + 1 end
				end
				if count == 0 then return 0 end
				return max(0, floor((current - total) / count))
			end
			-- W1: a real EXPAND inside; W0 only: just IupFills
			if band(e, ONE) ~= 0 then empty1 = empty(ONE)
			elseif band(e, ZERO) ~= 0 then empty0 = empty(ZERO) end
			if L.shrink() then deficit = total - current end
			if deficit > 0 then
				for _, c in ipairs(items) do
					local cs = STATE[c]
					if band(cs.expand or 0, ONE) ~= 0 then
						slack_total = slack_total + (vertical and cs.nat_h or cs.nat_w) - Layout.minContent(c, not vertical)
					end
				end
			end
		end
		local client_cross = max(0, (vertical and st.w or st.h) - 2 * (vertical and mx or my))
		local align = alignment(st, vertical)
		local pos = (vertical and st.y + my or st.x + mx)
		local cross0 = vertical and st.x + mx or st.y + my
		for _, c in ipairs(items) do
			local cs = STATE[c]
			local size_along
			if homogeneous_size > 0 or d.homogeneous then
				size_along = homogeneous_size
			else
				local ce = cs.expand or 0
				local extra = band(ce, ONE) ~= 0 and empty1 or (band(ce, ZERO) ~= 0 and empty0 or 0)
				local weight = tonumber(cs.attrs.EXPANDWEIGHT)
				if weight then extra = floor(extra * weight + 0.5) end
				if deficit > 0 and slack_total > 0 and band(ce, ONE) ~= 0 then
					local slack = (vertical and cs.nat_h or cs.nat_w) - Layout.minContent(c, not vertical)
					extra = -min(slack, floor(deficit * slack / slack_total))
				end
				size_along = (vertical and cs.nat_h or cs.nat_w) + extra
			end
			local cw, ch
			if vertical then cw, ch = L.currentSize(c, client_cross, size_along)
			else cw, ch = L.currentSize(c, size_along, client_cross) end
			local cross_size = vertical and cw or ch
			local offset = floor((client_cross - cross_size) * align)
			if offset < 0 then offset = 0 end
			if vertical then
				cs.x, cs.y, cs.w, cs.h = cross0 + offset, pos, cw, ch
			else
				cs.x, cs.y, cs.w, cs.h = pos, cross0 + offset, cw, ch
			end
			Layout.placeChildren(c, cs)
			if d.homogeneous then pos = pos + homogeneous_size + g
			else pos = pos + (vertical and ch or cw) + g end
		end
	end
end

--- iupStrToIntInt(value, &a, &b, 'x'): either side may be missing (0 here).
local function int_int(value)
	local a, b = tostring(value):match("^%s*(-?%d*)%s*x?%s*(-?%d*)")
	return tonumber(a) or 0, tonumber(b) or 0
end

--- iHboxSetRasterSizeAttrib / iHboxSetSizeAttrib and the vbox's: a box sets only its own
-- axis ("can NOT set height" / "can NOT set width"). A value without a positive size there
-- leaves the user size as it was. The vbox takes the second number when there is one, else
-- the first ("200" is a height of 200). RASTERSIZE always clears SIZE; SIZE is kept for a
-- font change, as IUP keeps it in the hash table.
local function box_size_setters(vertical)
	local function along(value)
		local a, b = int_int(value)
		if vertical and b ~= 0 then a = b end
		return a
	end
	local function norm(n) return vertical and ("x" .. n) or (n .. "x") end
	return {
		RASTERSIZE = function(el, st, value)
			st.attrs.SIZE = nil
			if value == nil then st.attrs.RASTERSIZE, st.attrs.USERSIZE = nil, nil; return false end
			local n = along(value)
			if n > 0 then st.attrs.RASTERSIZE, st.attrs.USERSIZE = norm(n), nil end
			return false
		end,
		SIZE = function(el, st, value)
			if value == nil then
				st.attrs.SIZE, st.attrs.RASTERSIZE, st.attrs.USERSIZE = nil, nil, nil
				return false
			end
			local n = along(value)
			if n > 0 then st.attrs.SIZE, st.attrs.RASTERSIZE, st.attrs.USERSIZE = norm(n), nil, nil end
			return false
		end,
	}
end

Classes.define({
	name = "hbox", children = -1, type = "void",
	stacksAlong = function(el, st, horizontal) return horizontal end, -- iupLayoutMinContent
	natural = box_natural(false), place = box_place(false),
	set = box_size_setters(false),
	get = {
		ORIENTATION = function() return "HORIZONTAL" end,
		ALIGNMENT = function(el, st) return st.attrs.ALIGNMENT or "ATOP" end,
	},
})

Classes.define({
	name = "vbox", children = -1, type = "void",
	stacksAlong = function(el, st, horizontal) return not horizontal end, -- iupLayoutMinContent
	natural = box_natural(true), place = box_place(true),
	set = box_size_setters(true),
	get = {
		ORIENTATION = function() return "VERTICAL" end,
		ALIGNMENT = function(el, st) return st.attrs.ALIGNMENT or "ALEFT" end,
	},
})

-- zbox ---------------------------------------------------------------------------------

--- The child a zbox (or anything zbox-like) shows: VALUE_HANDLE, VALUE (a name or handle
-- name), VALUEPOS, else the first child.
local function zbox_current(el, st)
	local kids = st.children
	if #kids == 0 then return nil end
	local h = st.data.value
	if h then
		for _, c in ipairs(kids) do if c == h then return c end end
	end
	return kids[1]
end
M.zboxCurrent = zbox_current

local function zbox_select(el, st, child)
	if st.data.value == child then return end
	st.data.value = child
end

local function find_child(el, st, value, handle)
	if handle then return handle end
	if value == nil then return nil end
	local named = Element.named[value]
	if named then return named end
	for _, c in ipairs(st.children) do
		local cs = STATE[c]
		if cs and (cs.attrs.NAME == value or cs.handlename == value) then return c end
	end
	return nil
end

local ZALIGN = {
	NORTH = { 0.5, 0 }, SOUTH = { 0.5, 1 }, WEST = { 0, 0.5 }, EAST = { 1, 0.5 },
	NE = { 1, 0 }, SE = { 1, 1 }, SW = { 0, 1 }, NW = { 0, 0 }, ACENTER = { 0.5, 0.5 },
}

Classes.define({
	name = "zbox", children = -1, type = "void",
	visibleChildren = function(el, st)
		local c = zbox_current(el, st)
		return c and { c } or {}
	end,
	childRemoved = function(el, st, child, pos)
		if st.data.value == child then st.data.value = st.children[math.min(pos, #st.children)] end
	end,
	set = {
		VALUE = function(el, st, value, handle)
			local c = find_child(el, st, value, handle)
			if c then zbox_select(el, st, c) end
			return false
		end,
		VALUE_HANDLE = function(el, st, value, handle)
			local c = find_child(el, st, value, handle)
			if c then zbox_select(el, st, c) end
			return false
		end,
		VALUEPOS = function(el, st, value)
			local c = st.children[(tonumber(value) or -1) + 1]
			if c then zbox_select(el, st, c) end
			return false
		end,
	},
	get = {
		VALUE = function(el, st)
			local c = zbox_current(el, st)
			local cs = c and STATE[c]
			if not cs then return nil end
			return cs.handlename or Element.autoName(c)
		end,
		VALUEPOS = function(el, st)
			local c = zbox_current(el, st)
			if not c then return nil end
			return tostring(Element.childPos(el, c))
		end,
		VALUE_HANDLE = function(el, st) return nil end,
		COUNT = function(el, st) return tostring(#st.children) end,
	},
	methods = nil,
	-- iZboxComputeNaturalSizeMethod: CHILDSIZEALL (registered "Yes") measures every child,
	-- hidden ones included; NO only the current one
	natural = function(el, st, L)
		local all = Element.isTrue(Element.getAttribute(el, "CHILDSIZEALL"))
		local current = zbox_current(el, st)
		local w, h, ce = 0, 0, 0
		for _, c in ipairs(st.children) do
			local cs = STATE[c]
			if cs and (all or c == current) and not Layout.floating(cs) then
				ce = bit.bor(ce, cs.expand or 0)
				w, h = max(w, cs.nat_w or 0), max(h, cs.nat_h or 0)
			end
		end
		return w, h, ce
	end,
	place = function(el, st, L)
		local a = ZALIGN[(own(st, "ALIGNMENT") or "NW"):upper()] or ZALIGN.NW
		for _, c in ipairs(st.children) do
			local cs = STATE[c]
			if cs then
				if Layout.floating(cs) then Layout.placeFloating(c, cs, st)
				else
					local cw, ch = L.currentSize(c, st.w, st.h)
					cs.x = st.x + floor((st.w - cw) * a[1])
					cs.y = st.y + floor((st.h - ch) * a[2])
					cs.w, cs.h = cw, ch
					Layout.placeChildren(c, cs)
				end
			end
		end
	end,
})

-- The zbox VALUE_HANDLE getter needs the handle itself, which a string getter cannot
-- return: iup.GetAttributeHandle goes through Element.getHandle, so answer there.
do
	local raw = Element.getHandle
	Element.getHandle = function(el, name)
		local st = STATE[el]
		if st and name == "VALUE_HANDLE" and st.classname == "zbox" then return zbox_current(el, st) end
		return raw(el, name)
	end
end

-- fill ---------------------------------------------------------------------------------

local function fill_dir(st)
	local p = st.parent and STATE[st.parent]
	if not p then return nil end
	if p.classname == "hbox" then return "H" end
	if p.classname == "vbox" then return "V" end
	if p.classname == "gridbox" then
		return (Element.getAttribute(st.parent, "ORIENTATION") or "HORIZONTAL") == "HORIZONTAL" and "H" or "V"
	end
	return nil
end

local function fill_natural(el, st, L)
	-- A fill measures only along its box: its user size there, or nothing and expand.
	local uw, uh = Layout.userSize(el, st)
	local dir = fill_dir(st)
	return uw, uh, nil
end

Classes.define({
	name = "fill", children = 0, type = "void", transparent = true,
	natural = fill_natural,
	expandOverride = function(el, st, L)
		local dir = fill_dir(st)
		local uw, uh = Layout.userSize(el, st)
		if dir == "H" then
			-- only along the box, and only without a size there
			return uw <= 0 and E.W0 or 0
		elseif dir == "V" then
			return uh <= 0 and E.H0 or 0
		end
		return 0
	end,
	get = {
		EXPAND = function(el, st)
			local dir = fill_dir(st)
			local uw, uh = Layout.userSize(el, st)
			if dir == "H" and uw <= 0 then return "HORIZONTAL" end
			if dir == "V" and uh <= 0 then return "VERTICAL" end
			return "NO"
		end,
	},
})
Classes.define({ name = "spacer", children = 0, type = "void", transparent = true, natural = fill_natural,
	expandOverride = Classes.get("fill").expandOverride })

-- cbox: children at CX/CY ------------------------------------------------------------------

Classes.define({
	name = "cbox", children = -1, type = "void",
	natural = function(el, st, L)
		local w, h = 0, 0
		for _, c in ipairs(st.children) do
			local cs = STATE[c]
			if cs and not Layout.floating(cs) then
				local cx = tonumber(cs.attrs.CX) or 0
				local cy = tonumber(cs.attrs.CY) or 0
				w, h = max(w, cx + (cs.nat_w or 0)), max(h, cy + (cs.nat_h or 0))
			end
		end
		return w, h
	end,
	place = function(el, st, L)
		for _, c in ipairs(st.children) do
			local cs = STATE[c]
			if cs then
				local cx = tonumber(cs.attrs.CX) or 0
				local cy = tonumber(cs.attrs.CY) or 0
				cs.x, cs.y, cs.w, cs.h = st.x + cx, st.y + cy, cs.nat_w or 0, cs.nat_h or 0
				Layout.placeChildren(c, cs)
			end
		end
	end,
})

-- gridbox -------------------------------------------------------------------------------

Classes.define({
	name = "gridbox", children = -1, type = "void",
	natural = function(el, st, L)
		local numdiv = max(1, tonumber(own(st, "NUMDIV")) or 1)
		local horizontal = (own(st, "ORIENTATION") or "HORIZONTAL"):upper() == "HORIZONTAL"
		local mx, my = margins(el, st, L)
		local gl, gc = tonumber(own(st, "GAPLIN")) or 0, tonumber(own(st, "GAPCOL")) or 0
		local cols, rows = {}, {}
		local i = 0
		for _, c in ipairs(st.children) do
			local cs = STATE[c]
			if cs and not Layout.floating(cs) then
				local col, row
				if horizontal then col, row = i % numdiv, floor(i / numdiv) else row, col = i % numdiv, floor(i / numdiv) end
				cols[col + 1] = max(cols[col + 1] or 0, cs.nat_w or 0)
				rows[row + 1] = max(rows[row + 1] or 0, cs.nat_h or 0)
				i = i + 1
			end
		end
		st.data.cols, st.data.rows, st.data.mx, st.data.my, st.data.gl, st.data.gc = cols, rows, mx, my, gl, gc
		st.data.numdiv, st.data.horizontal = numdiv, horizontal
		local w, h = 2 * mx + gc * max(#cols - 1, 0), 2 * my + gl * max(#rows - 1, 0)
		for _, v in ipairs(cols) do w = w + v end
		for _, v in ipairs(rows) do h = h + v end
		return w, h
	end,
	place = function(el, st, L)
		local d = st.data
		local cols, rows = d.cols or {}, d.rows or {}
		local i = 0
		for _, c in ipairs(st.children) do
			local cs = STATE[c]
			if cs then
				if Layout.floating(cs) then Layout.placeFloating(c, cs, st)
				else
					local col, row
					if d.horizontal then col, row = i % d.numdiv, floor(i / d.numdiv) else row, col = i % d.numdiv, floor(i / d.numdiv) end
					local x, y = st.x + d.mx, st.y + d.my
					for k = 1, col do x = x + cols[k] + d.gc end
					for k = 1, row do y = y + rows[k] + d.gl end
					L.place(c, x, y, cols[col + 1] or 0, rows[row + 1] or 0)
					i = i + 1
				end
			end
		end
	end,
})

-- one-child containers -------------------------------------------------------------------

local function one_natural(el, st, L)
	local c = st.children[1]
	local cs = c and STATE[c]
	if not cs or Layout.floating(cs) then return 0, 0 end
	return cs.nat_w or 0, cs.nat_h or 0
end

local function one_place(el, st, L)
	for _, c in ipairs(st.children) do
		local cs = STATE[c]
		if cs then
			if Layout.floating(cs) then Layout.placeFloating(c, cs, st)
			else L.place(c, st.x, st.y, st.w, st.h) end
		end
	end
end

Classes.define({ name = "radio", children = 1, type = "void", natural = one_natural, place = one_place,
	get = {
		VALUE = function(el, st)
			local found
			local function walk(e)
				local s = STATE[e]
				if not s or found then return end
				if (s.classname == "toggle" or s.classname == "flattoggle") and Element.getAttribute(e, "VALUE") == "ON" then
					found = s.attrs.NAME or s.handlename
				end
				for _, c in ipairs(s.children) do walk(c) end
			end
			walk(el)
			return found
		end,
	},
})
Classes.define({ name = "normalizer", children = -1, type = "void", natural = function() return 0, 0 end,
	place = function() end, visibleChildren = function() return {} end, transparent = true })
Classes.define({ name = "sbox", children = 1, type = "void", natural = one_natural, place = one_place })
Classes.define({ name = "user", children = -1, type = "other", natural = function() return 0, 0 end,
	place = function() end, visibleChildren = function() return {} end, transparent = true })

Classes.define({
	name = "backgroundbox", children = 1, type = "canvas", opaque = true,
	natural = function(el, st, L)
		local w, h = one_natural(el, st, L)
		local b = Element.getAttribute(el, "BORDER") == "YES" and 2 or 0
		return w + b, h + b
	end,
	place = function(el, st, L)
		local b = Element.getAttribute(el, "BORDER") == "YES" and 1 or 0
		local c = st.children[1]
		if c then L.place(c, st.x + b, st.y + b, st.w - 2 * b, st.h - 2 * b) end
	end,
	draw = function(el, st, dc)
		local bg = Element.getAttribute(el, "BGCOLOR")
		if bg then dc:fill(st.x, st.y, st.w, st.h, bg) end
		if Element.getAttribute(el, "BORDER") == "YES" then
			dc:rect(st.x, st.y, st.w, st.h, Element.getAttribute(el, "BORDERCOLOR") or "128 128 128")
		end
	end,
})

-- The classic iup.frame: a 1px etched border, the title cut into the top edge.
Classes.define({
	name = "frame", children = 1, type = "control", opaque = true,
	natural = function(el, st, L)
		local w, h = one_natural(el, st, L)
		local title = Element.getAttribute(el, "TITLE")
		local top = 2
		if title and title ~= "" then
			local _, ch = L.charsize(el)
			top = ch
		end
		st.data.top = top
		return w + 4, h + top + 2
	end,
	place = function(el, st, L)
		local c = st.children[1]
		local top = st.data.top or 2
		if c then L.place(c, st.x + 2, st.y + top, st.w - 4, st.h - top - 2) end
	end,
	draw = function(el, st, dc)
		local bg = Element.getAttribute(el, "BGCOLOR")
		local fg = Element.getAttribute(el, "FGCOLOR") or "0 0 0"
		local color = Element.getAttribute(el, "FRAMECOLOR") or "160 160 160"
		local title = Element.getAttribute(el, "TITLE")
		local top = st.data.top or 2
		local y = st.y + (title and title ~= "" and math.floor(top / 2) or 0)
		dc:rect(st.x, y, st.w, st.h - (y - st.y), color)
		if title and title ~= "" then
			local font = require("core.imgui.Fonts").forElement(el)
			local tw = dc:measure(title, font)
			if bg then dc:fill(st.x + 6, st.y, tw + 4, top, bg) end
			dc:text(title, st.x + 8, st.y, tw, top, fg, font, { valign = "center" })
		end
	end,
})

return M
