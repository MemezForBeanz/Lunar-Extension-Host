local Classes = require("core.imgui.Classes")
local Element = require("core.imgui.Element")
local FlatScrollbar = require("core.imgui.widgets.flatscrollbar")

local function attr(e, n) return Element.getAttribute(e, n) end
local function own(e, n) return Element.own(e, n) end
local yes = Element.isTrue -- iupStrBoolean
local function num(v, d) return tonumber(v) or d or 0 end
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function pair(v)
	local a, b = tostring(v or ""):match("^%s*(-?%d*)x(-?%d*)%s*$")
	return tonumber(a), tonumber(b)
end
local function user_child(e) return FlatScrollbar.user_child(e) end

local function set_pos(e, st, x, y)
	local dx, dy = st.data.dx or 0, st.data.dy or 0
	st.data.posx = clamp(num(x), 0, math.max(0, (st.data.xmax or 0) - dx))
	st.data.posy = clamp(num(y), 0, math.max(0, (st.data.ymax or 0) - dy))
	local child = user_child(e)
	if child then
		local cs = Element.state(child)
		if cs then cs.x, cs.y = st.x - st.data.posx, st.y - st.data.posy end
	end
	Element.hooks.invalidate(e, "paint", "POS")
	local cb = Element.call(e, "SCROLL_CB", 0, st.data.posx, st.data.posy)
	if cb == nil then Element.call(e, "FLATSCROLL_CB") end
	Element.call(e, "LAYOUTUPDATE_CB")
	FlatScrollbar.sync(e)
end

local function scroll_to_child(e, st, child)
	local x, y = st.data.posx or 0, st.data.posy or 0
	local c = child
	while c and c ~= e do
		local cs = Element.state(c)
		x = x + (cs and cs.x or 0)
		y = y + (cs and cs.y or 0)
		c = cs and cs.parent
	end
	if c == e then set_pos(e, st, x, y) end
end

local function scroll_set(e, st, value, handle)
	local name = tostring(value or ""):upper()
	if name == "TOP" then set_pos(e, st, 0, 0)
	elseif name == "BOTTOM" then set_pos(e, st, st.data.posx, (st.data.ymax or 0) - (st.data.dy or 0))
	elseif name:match("^%s*-?%d+%s*,%s*-?%d+") then
		local x, y = name:match("^%s*(-?%d+)%s*,%s*(-?%d+)")
		set_pos(e, st, x, y)
	elseif handle then scroll_to_child(e, st, handle)
	end
	return false
end

--- iFlatScrollBoxComputeNaturalSizeMethod: free of the child (0x0), except before the
-- first layout, when it starts at the child's natural size. CANVASBOX: no natural size.
local function scroll_natural(e, st, L)
	local c = user_child(e)
	if yes(attr(e, "CANVASBOX")) then return 0, 0 end
	if (st.w or 0) == 0 and (st.h or 0) == 0 and c then return L.natural(c) end
	return 0, 0
end

--- Which bars may show: iupFlatScrollBarGet reads FLATSCROLLBAR (default YES; SCROLLBAR is
-- read-only NO on IupFlatScrollBox); IupScrollBox reads its native SCROLLBAR (default YES,
-- iScrollBoxHasVertScroll) and its bars are the system's width.
local SYSTEM_SB_SIZE = 17 -- iupdrvGetScrollbarSize: SM_CXVSCROLL at 96 DPI
local function bars(e, native)
	local v = tostring(attr(e, native and "SCROLLBAR" or "FLATSCROLLBAR") or ""):upper()
	local horiz = v == "YES" or v == "HORIZONTAL"
	local vert = v == "YES" or v == "VERTICAL"
	local size = native and SYSTEM_SB_SIZE or num(attr(e, "SCROLLBARSIZE"), 15)
	if not native and yes(attr(e, "SHOWFLOATING")) then size = 0 end
	return horiz, vert, size
end

--- iFlatScrollBoxSetChildrenCurrentSizeMethod, iFlatScrollBoxUpdateVisibleScrollArea and
-- iFlatScrollBoxUpdateChildPos (iScrollBoxSetChildrenCurrentSizeMethod for IupScrollBox).
local function scroll_place_for(native)
	return function(e, st, L)
		local c = user_child(e)
		local d = st.data
		if not c then
			d.xmax, d.ymax, d.dx, d.dy = 0, 0, 0, 0
			FlatScrollbar.sync(e)
			return
		end
		local sb_horiz, sb_vert, sb_size = bars(e, native)
		-- If the child is greater than the box, it keeps its natural size, else it gets the
		-- box's. The fork's FITCONTENT measures what the child cannot give up instead.
		local need_w, need_h = L.natural(c)
		if not native and yes(attr(e, "FITCONTENT")) then
			need_w = math.min(need_w, L.minContent(c, true))
			need_h = math.min(need_h, L.minContent(c, false))
		end
		local w, h, has_h, has_v = st.w, st.h, false, false
		if need_w > st.w then w = need_w; has_h = sb_horiz end
		if need_h > st.h then h = need_h; has_v = sb_vert end
		if not has_h and has_v then w = w - sb_size end -- reduce expand space
		if has_h and not has_v then h = h - sb_size end
		local cw, ch = L.currentSize(c, w, h)
		-- the actual child size is the virtual area
		d.xmax = sb_horiz and cw or 0
		d.ymax = sb_vert and ch or 0
		-- the visible area: a bar in one direction takes room from the other
		local canvas_w, canvas_h = st.w, st.h
		if cw > st.w and sb_horiz then canvas_h = canvas_h - sb_size end
		if ch > st.h and sb_vert then canvas_w = canvas_w - sb_size end
		if cw <= st.w and cw > canvas_w and sb_horiz then canvas_h = canvas_h - sb_size end
		if ch <= st.h and ch > canvas_h and sb_vert then canvas_w = canvas_w - sb_size end
		d.dx = sb_horiz and math.max(canvas_w, 0) or 0
		d.dy = sb_vert and math.max(canvas_h, 0) or 0
		-- iFlatScrollBarSetDXAttrib / SetDYAttrib: a view that holds everything scrolls to 0,
		-- else the position stays inside the range
		d.posx = d.dx >= d.xmax and 0 or clamp(num(d.posx), 0, d.xmax - d.dx)
		d.posy = d.dy >= d.ymax and 0 or clamp(num(d.posy), 0, d.ymax - d.dy)
		local posx, posy = d.posx, d.posy
		if d.dx > d.xmax - sb_size then posx = 0 end
		if d.dy > d.ymax - sb_size then posy = 0 end
		local ox, oy = pair(own(e, "CHILDOFFSET"))
		L.place(c, st.x + (ox or 0) - posx, st.y + (oy or 0) - posy, w, h)
		FlatScrollbar.sync(e)
	end
end
local scroll_place = scroll_place_for(false)

local function scroll_event(e, st, ev, rt)
	if ev.type == "wheel" then
		return FlatScrollbar.on_wheel(e, ev.dy or 0)
	end
	return false
end

local function scroll_defaults()
	return {
		SCROLLBARSIZE = "15", SB_INSET = "0", FLATSCROLLBAR = "YES", SHOWARROWS = "YES", -- iupFlatScrollBarRegister
		SHOWFLOATING = "NO", SHOWTRANSPARENCY = "NO", FITCONTENT = "NO", CANFOCUS = "NO",
		BGCOLOR = function() return Element.globals.DLGBGCOLOR end,
	}
end

local scroll_def = {
	name = "flatscrollbox", children = 1, clip = true,
	clipsContent = true, -- iupLayoutMinContent: it scrolls
	-- the bars are canvases with ZORDER=TOP: painted and hit after the content
	visibleChildren = FlatScrollbar.visible_children, defaults = scroll_defaults(),
	natural = scroll_natural, place = scroll_place, event = scroll_event,
	create = function(e) FlatScrollbar.create(e) end,
	-- iup_flatscrollbox.c: "set expand to its own expand so it will not depend on children"
	childrenExpand = function(el, st) return st.expand end,
	get = {
		POSX = function(e, s) return s.data.posx or 0 end, POSY = function(e, s) return s.data.posy or 0 end,
		DX = function(e, s) return s.data.dx or 0 end, DY = function(e, s) return s.data.dy or 0 end,
		XMAX = function(e, s) return s.data.xmax or 0 end, YMAX = function(e, s) return s.data.ymax or 0 end,
	},
	set = {
		SCROLLTO = scroll_set,
		SCROLLTOCHILD = scroll_set,
		SCROLLTOCHILD_HANDLE = scroll_set,
		POSX = function(e, s, v) set_pos(e, s, v, s.data.posy) return false end,
		POSY = function(e, s, v) set_pos(e, s, s.data.posx, v) return false end,
	},
	callbacks = { SCROLL_CB = true, FLATSCROLL_CB = true, LAYOUTUPDATE_CB = true },
}
local native_def = {}
for k, v in pairs(scroll_def) do native_def[k] = v end
native_def.name, native_def.defaults = "scrollbox", scroll_defaults()
native_def.defaults.FLATSCROLLBAR = "NO"
native_def.defaults.SCROLLBAR = "YES" -- iupClassRegisterReplaceAttribDef(ic, "SCROLLBAR", "YES")
native_def.place = scroll_place_for(true)
native_def.defaults.CANFOCUS = "NO"

Classes.define(scroll_def)
Classes.define(native_def)
return Classes
