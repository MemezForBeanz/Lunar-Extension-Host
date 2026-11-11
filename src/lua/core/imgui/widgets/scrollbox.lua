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
-- IupRefresh lays out at once; this host defers it to Runtime.layoutNow, so anything that
-- reads or moves the scroll range lays a pending dialog out first (the Log Parser sets
-- VALUE, refreshes, then SYNCFROMCHILD against the new YMAX).
local function fresh(e)
	local R = package.loaded["core.imgui.Runtime"]
	if R and R.layoutNow then R.layoutNow(e) end
end

-- Lunar fork (patch 0001, iup_flatscrollbox.c): NATIVETEXTSCROLL lets the flat bars drive a
-- native multiline text child's own line scroll. iFlatScrollBoxNativeTextMode: the box has
-- NATIVETEXTSCROLL and the child is a text (IupClassMatch(child, "text") also matches a
-- multiline, which is the text class with MULTILINE=YES).
local function native_text_child(e)
	if not yes(attr(e, "NATIVETEXTSCROLL")) then return nil end
	local c = user_child(e)
	local cs = c and Element.state(c)
	if cs and (cs.classname == "text" or cs.classname == "multiline") then return c, cs end
	return nil
end
-- iFlatScrollBoxNativeLineHeight: iupdrvFontGetCharSize of the child.
local function native_line_height(c)
	local _, h = require("core.imgui.Fonts").forElement(c):charsize()
	return math.max(1, h or 1)
end

local function set_pos(e, st, x, y)
	local dx, dy = st.data.dx or 0, st.data.dy or 0
	st.data.posx = clamp(num(x), 0, math.max(0, (st.data.xmax or 0) - dx))
	st.data.posy = clamp(num(y), 0, math.max(0, (st.data.ymax or 0) - dy))
	local child = user_child(e)
	local text = native_text_child(e)
	if text then
		-- iFlatScrollBoxUpdateChildPos, native mode: the EDIT stays put and POSY becomes its
		-- first visible line; the guard stops the scroll bouncing back into POSY.
		if not st.data.native_applying then
			st.data.native_applying = true
			local liney = st.data.native_liney or native_line_height(text)
			Element.setAttribute(text, "FIRSTVISIBLELINE", tostring(math.floor(st.data.posy / liney) + 1))
			st.data.native_applying = false
		end
	elseif child then
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
	fresh(e)
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
		local text, ts
		if not native then text, ts = native_text_child(e) end
		if text then
			-- iFlatScrollBoxSetChildrenCurrentSizeMethod, native mode: the EDIT keeps the
			-- viewport size (less the vertical bar) and the virtual height is its line count.
			local liney = native_line_height(text)
			local lines = math.max(1, tonumber(Element.getAttribute(text, "LINECOUNT")) or 1)
			local w = st.w
			if sb_vert then w = w - sb_size end
			w = math.max(0, w)
			L.currentSize(text, w, st.h)
			ts.data.flat_host, ts.data.flat_liney = e, liney
			d.native_liney = liney
			d.xmax, d.ymax, d.dx, d.dy = 0, lines * liney, 0, st.h
			d.posx = 0
			d.posy = d.dy >= d.ymax and 0 or clamp(num(d.posy), 0, d.ymax - d.dy)
			L.place(text, st.x, st.y, w, st.h)
			FlatScrollbar.sync(e)
			return
		end
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
		POSX = function(e, s) fresh(e); return s.data.posx or 0 end, POSY = function(e, s) fresh(e); return s.data.posy or 0 end,
		DX = function(e, s) fresh(e); return s.data.dx or 0 end, DY = function(e, s) fresh(e); return s.data.dy or 0 end,
		XMAX = function(e, s) fresh(e); return s.data.xmax or 0 end, YMAX = function(e, s) fresh(e); return s.data.ymax or 0 end,
	},
	set = {
		SCROLLTO = scroll_set,
		SCROLLTOCHILD = scroll_set,
		SCROLLTOCHILD_HANDLE = scroll_set,
		POSX = function(e, s, v) fresh(e); set_pos(e, s, v, s.data.posy) return false end,
		POSY = function(e, s, v) fresh(e); set_pos(e, s, s.data.posx, v) return false end,
		-- iFlatScrollBoxSetSyncFromChildAttrib: POSY follows the text's first visible line
		-- after the application moved it (SCROLLTO to a failure line).
		SYNCFROMCHILD = function(e, s)
			fresh(e)
			local text = native_text_child(e)
			if text then
				local liney = s.data.native_liney or native_line_height(text)
				local first = tonumber(Element.getAttribute(text, "FIRSTVISIBLELINE")) or 1
				s.data.native_applying = true
				set_pos(e, s, 0, (first - 1) * liney)
				s.data.native_applying = false
			end
			return false
		end,
	},
	callbacks = { SCROLL_CB = true, FLATSCROLL_CB = true, LAYOUTUPDATE_CB = true },
}
-- IupScrollBox (iup_scrollbox.c) is an IupCanvas: its bars are the Windows scroll bars of
-- the canvas's window (iupwin_canvas.c), in the non-client area, so the child lives in the
-- client rect left beside them. See core.imgui.widgets.winscrollbar.
local Win = require("core.imgui.widgets.winscrollbar")
local SB = Win.SIZE -- iupdrvGetScrollbarSize
local function fmt_double(v) return string.format("%.18f", v or 0) end -- iupStrReturnDouble

local function native_has(e)
	local v = tostring(attr(e, "SCROLLBAR") or ""):upper() -- iScrollBoxHasHorizScroll/VertScroll
	return v == "YES" or v == "HORIZONTAL", v == "YES" or v == "VERTICAL"
end

local function native_sync_bars(e, st)
	local d = st.data
	local wsb = d.wsb or {}
	if wsb.v then wsb.v.pos = d.posy or 0 end
	if wsb.h then wsb.h.pos = d.posx or 0 end
end

--- iScrollBoxUpdateChildPos: the child is placed again (SetChildrenPosition and
-- iupLayoutUpdate), then LAYOUTUPDATE_CB.
local function native_update_child_pos(e)
	Element.hooks.invalidate(e, "layout", "POS")
	Element.call(e, "LAYOUTUPDATE_CB")
end

--- winCanvasSetPosXAttrib / SetPosYAttrib: clamp and keep; the child is not moved and no
-- callback runs (it follows on the next layout or scroll).
local function native_set_pos_attr(e, st, vertical, value)
	local sb_h, sb_v = native_has(e)
	if not ((vertical and sb_v) or (not vertical and sb_h)) then return end
	local v = tonumber(value)
	if not v then return end
	local d = st.data
	local max = vertical and (d.ymax or 0) or (d.xmax or 0)
	local page = vertical and (d.dy or 0) or (d.dx or 0)
	if page >= max then return end
	v = math.max(0, math.min(max - page, v))
	if vertical then d.posy = v else d.posx = v end
	native_sync_bars(e, st)
	Element.hooks.invalidate(e, "paint", "POS")
end

--- iScrollBoxSetPos: IupSetInt(POSX), IupSetInt(POSY), then the child moves.
local function native_set_pos(e, st, x, y)
	native_set_pos_attr(e, st, false, math.floor(num(x)))
	native_set_pos_attr(e, st, true, math.floor(num(y)))
	native_update_child_pos(e)
end

local native_owner = {
	range = function(e, vertical)
		local d = Element.state(e).data
		if vertical then return d.ymax or 0, d.dy or 0, d.posy or 0 end
		return d.xmax or 0, d.dx or 0, d.posx or 0
	end,
	-- winCanvasProcessVerScroll's tail: keep the position, then winCanvasCallScrollCallback.
	-- IupScrollBox's own SCROLL_CB is iScrollBoxScroll_CB; an application's replaces it.
	scroll = function(e, vertical, pos, op)
		local st = Element.state(e)
		if vertical then st.data.posy = pos else st.data.posx = pos end
		native_sync_bars(e, st)
		Element.hooks.invalidate(e, "paint", "POS")
		if Element.hasCallback(e, "SCROLL_CB") then
			Element.call(e, "SCROLL_CB", op, st.data.posx or 0, st.data.posy or 0)
			return
		end
		if (op == 5 or op == 11) and not yes(attr(e, "LAYOUTDRAG")) then return end
		native_update_child_pos(e)
	end,
}

local function native_place(e, st, L)
	local c = user_child(e)
	local d = st.data
	if not c then
		d.xmax, d.ymax, d.dx, d.dy = 0, 0, 0, 0
		Win.set(e, nil, nil)
		return
	end
	-- iScrollBoxSetChildrenCurrentSizeMethod
	local sb_horiz, sb_vert = native_has(e)
	local need_w, need_h = L.natural(c)
	local w, h, has_h, has_v = st.w, st.h, false, false
	if need_w > st.w then w = need_w; has_h = sb_horiz end
	if need_h > st.h then h = need_h; has_v = sb_vert end
	if not has_h and has_v then w = w - SB end
	if has_h and not has_v then h = h - SB end
	local cw, ch = L.currentSize(c, w, h)
	d.xmax = sb_horiz and cw or 0
	d.ymax = sb_vert and ch or 0
	-- iScrollBoxUpdateVisibleScrollArea
	local canvas_w, canvas_h = st.w, st.h
	if cw > st.w and sb_horiz then canvas_h = canvas_h - SB end
	if ch > st.h and sb_vert then canvas_w = canvas_w - SB end
	if cw <= st.w and cw > canvas_w and sb_horiz then canvas_h = canvas_h - SB end
	if ch <= st.h and ch > canvas_h and sb_vert then canvas_w = canvas_w - SB end
	d.dx = sb_horiz and math.max(canvas_w, 0) or 0
	d.dy = sb_vert and math.max(canvas_h, 0) or 0
	-- winCanvasSetDXAttrib / SetDYAttrib with XAUTOHIDE/YAUTOHIDE (always YES here): a bar
	-- shows while the view is smaller than the range; a hidden one resets the position.
	local show_h = sb_horiz and d.dx < d.xmax
	local show_v = sb_vert and d.dy < d.ymax
	if sb_horiz then d.posx = show_h and clamp(num(d.posx), 0, d.xmax - d.dx) or 0 end
	if sb_vert then d.posy = show_v and clamp(num(d.posy), 0, d.ymax - d.dy) or 0 end
	Win.set(e,
		show_v and { x = st.x + st.w - SB, y = st.y, w = SB, h = math.max(0, st.h - (show_h and SB or 0)),
			max = d.ymax, page = d.dy, pos = d.posy } or nil,
		show_h and { x = st.x, y = st.y + st.h - SB, w = math.max(0, st.w - (show_v and SB or 0)), h = SB,
			max = d.xmax, page = d.dx, pos = d.posx } or nil)
	-- iScrollBoxSetChildrenPositionMethod: IupGetInt(POSX/POSY); no offset while the range is
	-- within a bar's width of the view
	local posx, posy = math.floor(num(d.posx)), math.floor(num(d.posy))
	if d.dx > d.xmax - SB then posx = 0 end
	if d.dy > d.ymax - SB then posy = 0 end
	local ox, oy = pair(own(e, "CHILDOFFSET"))
	L.place(c, st.x + (ox or 0) - posx, st.y + (oy or 0) - posy, w, h)
end

local function native_event(e, st, ev, rt)
	local t = ev.type
	if t == "wheel" then
		-- winCanvasMsgProc WM_MOUSEWHEEL: WHEEL_CB, else SB_LINEUP/SB_LINEDOWN once per whole
		-- notch when the canvas has a vertical bar (consumed even when nothing scrolls),
		-- else the parent gets it.
		if Element.hasCallback(e, "WHEEL_CB") then
			Element.call(e, "WHEEL_CB", ev.dy or 0, ev.lx or 0, ev.ly or 0, ev.status)
			return true
		end
		local _, sb_v = native_has(e)
		if not sb_v then return false end
		local dy = ev.dy or 0
		local n = math.floor(math.abs(dy) + 1e-6)
		for _ = 1, n do Win.process(e, native_owner, true, dy > 0 and "lineup" or "linedown") end
		return true
	elseif t == "press" and ev.button == 1 and Win.press(e, native_owner, ev.x, ev.y, rt) then
		return true
	elseif t == "move" and Win.move(e, native_owner, ev.x, ev.y, rt) then
		return true
	elseif t == "release" and ev.button == 1 and Win.release(e, native_owner, ev.x, ev.y, rt) then
		return true
	elseif t == "leave" then
		Win.leave(e, rt)
		return true
	end
	-- iScrollBoxButton_CB / iScrollBoxMotion_CB (the canvas's BUTTON_CB and MOTION_CB unless
	-- the application set its own): button 1 drags the content.
	local d = st.data
	if t == "press" or t == "release" then
		if Element.hasCallback(e, "BUTTON_CB") then
			Element.call(e, "BUTTON_CB", ev.iupbutton, t == "press" and 1 or 0, ev.lx, ev.ly, ev.status)
		elseif ev.button == 1 and t == "press" then
			d.drag_sb = { x = ev.lx, y = ev.ly, posx = math.floor(num(d.posx)), posy = math.floor(num(d.posy)) }
		elseif ev.button == 1 then
			d.drag_sb = nil
		end
		if t == "press" then
			if rt and rt.capture then rt.capture(e) end
		elseif rt and rt.release then rt.release() end
		return true
	elseif t == "move" then
		if Element.hasCallback(e, "MOTION_CB") then
			Element.call(e, "MOTION_CB", ev.lx, ev.ly, ev.status)
		elseif d.drag_sb and tostring(ev.status or ""):sub(3, 3) == "1" then
			-- "drag direction is opposite to scrollbar"
			native_set_pos(e, st, d.drag_sb.posx - (ev.lx - d.drag_sb.x), d.drag_sb.posy - (ev.ly - d.drag_sb.y))
		end
		return true
	end
	return false
end

--- iScrollBoxSetScrollToChildHandleAttrib: scroll to the child's place in the content.
local function native_scroll_to_child(e, st, child)
	local cs = Element.state(child)
	if not cs or child == e then return false end
	local c, inside = cs.parent, false
	while c do
		if c == e then inside = true; break end
		local s = Element.state(c)
		c = s and s.parent
	end
	if not inside then return false end
	local x = cs.x - st.x + math.floor(num(st.data.posx))
	local y = cs.y - st.y + math.floor(num(st.data.posy))
	native_set_pos(e, st, x, y)
	return false
end

local native_def = {
	name = "scrollbox", children = 1, clipsContent = true,
	clipRect = function(e, st) return Win.client(e, st) end,
	natural = scroll_natural, place = native_place, event = native_event,
	-- WM_ERASEBKGND without ACTION fills the client with BGCOLOR
	draw = function(e, st, dc)
		local bg = attr(e, "BGCOLOR")
		if bg then
			local x, y, w, h = Win.client(e, st)
			dc:fill(x, y, w, h, bg)
		end
	end,
	drawAfter = function(e, st, dc, rt)
		Win.tick(e, native_owner, rt)
		Win.draw(e, st, dc)
	end,
	childrenExpand = function(el, st) return st.expand end,
	defaults = {
		SCROLLBAR = "YES", -- iupClassRegisterReplaceAttribDef(ic, "SCROLLBAR", "YES")
		CANFOCUS = "NO", WHEELDROPFOCUS = "YES", LAYOUTDRAG = "YES", BORDER = "NO",
		XAUTOHIDE = "YES", YAUTOHIDE = "YES",
		BGCOLOR = function() return Element.globals.DLGBGCOLOR end,
	},
	get = {
		POSX = function(e, s) return fmt_double(s.data.posx) end,
		POSY = function(e, s) return fmt_double(s.data.posy) end,
		DX = function(e, s) return tostring(s.data.dx or 0) end, DY = function(e, s) return tostring(s.data.dy or 0) end,
		XMAX = function(e, s) return tostring(s.data.xmax or 0) end, YMAX = function(e, s) return tostring(s.data.ymax or 0) end,
		XMIN = function() return "0" end, YMIN = function() return "0" end,
	},
	set = {
		-- iScrollBoxSetScrollToAttrib
		SCROLLTO = function(e, st, value)
			local v = tostring(value or "")
			if v:upper() == "TOP" then native_set_pos(e, st, 0, 0)
			elseif v:upper() == "BOTTOM" then native_set_pos(e, st, 0, num(st.data.ymax) - num(st.data.dy))
			else
				local x, y = v:match("^%s*(-?%d+)%s*,%s*(-?%d+)")
				if x then native_set_pos(e, st, tonumber(x), tonumber(y)) end
			end
			return false
		end,
		SCROLLTOCHILD = function(e, st, value, handle)
			local h = handle or (type(value) == "string" and require("core.imgui.iup").GetHandle(value))
			if h then native_scroll_to_child(e, st, h) end
			return false
		end,
		SCROLLTOCHILD_HANDLE = function(e, st, value, handle)
			if handle then native_scroll_to_child(e, st, handle) end
			return false
		end,
		POSX = function(e, s, v) native_set_pos_attr(e, s, false, v) return false end,
		POSY = function(e, s, v) native_set_pos_attr(e, s, true, v) return false end,
		BORDER = function() return false end, -- IUPAF_READONLY
	},
	callbacks = { SCROLL_CB = true, LAYOUTUPDATE_CB = true, BUTTON_CB = true, MOTION_CB = true, WHEEL_CB = true },
}

Classes.define(scroll_def)
Classes.define(native_def)
return Classes
