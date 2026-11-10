local Classes = require("core.imgui.Classes")
local Element = require("core.imgui.Element")
local Color = require("core.imgui.Color")
local FlatScrollbar = require("core.imgui.widgets.flatscrollbar")

local function attr(e, n) return Element.getAttribute(e, n) end
local function own(e, n) return Element.own(e, n) end
local function yes(v) return tostring(v or ""):upper() == "YES" end
local function num(v, d) return tonumber(v) or d or 0 end
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function pair(v)
	local a, b = tostring(v or ""):match("^%s*(-?%d*)x(-?%d*)%s*$")
	return tonumber(a), tonumber(b)
end
local function user_child(e) return FlatScrollbar.user_child(e) end

local function bar_size(e)
	if yes(attr(e, "SHOWFLOATING")) then return 0 end
	return math.max(0, num(attr(e, "SCROLLBARSIZE"), 15))
end

local function scroll_state(e, st, L)
	local c = user_child(e)
	local cw, ch = c and L.natural(c) or 0, c and select(2, L.natural(c)) or 0
	local rw, rh = pair(own(e, "RASTERSIZE"))
	local sw, sh = pair(own(e, "SIZE"))
	local fcw, fch = rw or (sw and sw * L.charsize(e) / 4) or 0, rh or (sh and sh * select(2, L.charsize(e)) / 8) or 0
	st.data.content_w, st.data.content_h = cw, ch
	return fcw, fch
end

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

local function scroll_natural(e, st, L)
	local rw, rh = scroll_state(e, st, L)
	if rw > 0 or rh > 0 then return rw, rh end
	if st.w == 0 and st.h == 0 and user_child(e) then return L.natural(user_child(e)) end
	return 0, 0
end

local function scroll_place(e, st, L)
	local c = user_child(e)
	if not c then return end
	local nw, nh = L.natural(c)
	local sb = bar_size(e)
	local vpw, vph = st.w, st.h
	local vertical = tostring(attr(e, "SCROLLBAR") or "VERTICAL"):upper()
	local hv = vertical == "HORIZONTAL" or vertical == "YES" or vertical == "BOTH"
	local vv = vertical ~= "HORIZONTAL" and vertical ~= "NO"
	local cw = math.max(nw, vpw - ((vv and nw > vpw) and sb or 0))
	local ch = math.max(nh, vph - ((hv and nh > vph) and sb or 0))
	if yes(attr(e, "FITCONTENT")) then
		cw = math.min(cw, L.minContent and L.minContent(c, true) or cw)
		ch = math.min(ch, L.minContent and L.minContent(c, false) or ch)
	end
	st.data.xmax, st.data.ymax = hv and cw or 0, vv and ch or 0
	st.data.dx, st.data.dy = vpw, vph
	set_pos(e, st, st.data.posx, st.data.posy)
	L.place(c, st.x - (st.data.posx or 0), st.y - (st.data.posy or 0), cw, ch)
end

local function draw_bar(e, st, dc, vertical)
	local maxv = vertical and st.data.ymax or st.data.xmax
	local view = vertical and st.data.dy or st.data.dx
	if not maxv or not view or maxv <= view then return end
	local size = bar_size(e)
	local x, y, w, h
	if vertical then x, y, w, h = st.x + st.w - size, st.y, size, st.h
	else x, y, w, h = st.x, st.y + st.h - size, st.w, size end
	local pos = vertical and st.data.posy or st.data.posx
	local range = vertical and st.data.ymax or st.data.xmax
	local track = vertical and h or w
	local thumb = math.max(8, track * view / range)
	local offset = (track - thumb) * pos / math.max(1, range - view)
	local fg = attr(e, "SB_FORECOLOR") or attr(e, "HIGHCOLOR") or attr(e, "FORECOLOR") or attr(e, "FGCOLOR")
	local bg = attr(e, "SB_BACKCOLOR") or attr(e, "BACKCOLOR") or attr(e, "BGCOLOR")
	if yes(attr(e, "SHOWTRANSPARENCY")) then bg = nil end
	if bg then dc:fill(x, y, w, h, bg, { radius = num(attr(e, "CORNERRADIUS")) }) end
	if vertical then dc:fill(x + 2, y + offset + 2, math.max(2, w - 4), math.max(2, thumb - 4), fg, { radius = math.min(4, w / 2) })
	else dc:fill(x + offset + 2, y + 2, math.max(2, thumb - 4), math.max(2, h - 4), fg, { radius = math.min(4, h / 2) }) end
end

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
		SCROLLBAR = "VERTICAL", BGCOLOR = function() return Element.globals.DLGBGCOLOR end,
	}
end

local scroll_def = {
	name = "flatscrollbox", children = 1, clip = true, visibleChildren = FlatScrollbar.visible_children, defaults = scroll_defaults(),
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
native_def.defaults.CANFOCUS = "NO"

Classes.define(scroll_def)
Classes.define(native_def)
return Classes
