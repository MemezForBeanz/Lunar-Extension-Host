-- Shared IUP flat scrollbar.  The owner keeps POSX/POSY and XMAX/YMAX; the two
-- internal canvas children only own the hit target and painting.
-- @module core.imgui.widgets.flatscrollbar
local Classes = require("core.imgui.Classes")
local Element = require("core.imgui.Element")
local iup = require("core.imgui.iup")
local FlatDraw = require("core.imgui.widgets.flatdraw")

local M = {}
local function attr(e, n) return Element.getAttribute(e, n) end
local function num(v, d) return tonumber(v) or d or 0 end
local yes = Element.isTrue -- iupStrBoolean
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function owner(e) return Element.state(e).data.scroll_owner end

local function axis(owner_el, vertical)
	local s = Element.state(owner_el)
	local size = num(attr(owner_el, "SCROLLBARSIZE"), 15)
	local maxv = num(attr(owner_el, vertical and "YMAX" or "XMAX"))
	local view = num(attr(owner_el, vertical and "DY" or "DX"))
	local pos = num(attr(owner_el, vertical and "POSY" or "POSX"))
	local track = vertical and s.h or s.w
	local other = vertical and num(attr(owner_el, "XMAX")) > num(attr(owner_el, "DX"))
		or num(attr(owner_el, "YMAX")) > num(attr(owner_el, "DY"))
	local arrows = yes(attr(owner_el, "SHOWARROWS")) and not yes(attr(owner_el, "SHOWTRANSPARENT"))
	local arrow = arrows and size or 0
	if not yes(attr(owner_el, "SHOWFLOATING")) and other then track = track - size end
	local range = math.max(0, track - 1 - 2 * arrow)
	if maxv <= view or track <= 0 then return nil end
	local thumb = math.max(size, math.floor(view * range / math.max(1, maxv)))
	local offset = arrow + (pos * math.max(0, range - thumb) / math.max(1, maxv - view))
	return size, track, arrow, thumb, offset, maxv, view, pos
end

local function notify(e, op)
	local x, y = num(attr(e, "POSX")), num(attr(e, "POSY"))
	local cb = Element.call(e, "SCROLL_CB", op, x, y)
	if op == nil or cb == nil then Element.call(e, "FLATSCROLL_CB") end
end

local function set_pos(e, x, y, op)
	local xmax, ymax = num(attr(e, "XMAX")), num(attr(e, "YMAX"))
	local dx, dy = num(attr(e, "DX")), num(attr(e, "DY"))
	x, y = clamp(num(x), 0, math.max(0, xmax - dx)), clamp(num(y), 0, math.max(0, ymax - dy))
	Element.setAttribute(e, "POSX", tostring(x))
	Element.setAttribute(e, "POSY", tostring(y))
	notify(e, op)
	M.sync(e)
end

local function draw_arrow(dc, x, y, size, vertical, positive, color, bg)
	local c = x + size / 2
	local d = y + size / 2
	local p
	if vertical then
		p = positive and { c - 4, d - 2, c + 4, d - 2, c, d + 3 } or { c, d - 3, c - 4, d + 2, c + 4, d + 2 }
	else
		p = positive and { c - 2, d - 4, c - 2, d + 4, c + 3, d } or { c + 2, d - 4, c + 2, d + 4, c - 3, d }
	end
	dc:poly(p, color, { filled = true })
end

local function scrollbar_draw(sb, st, dc)
	local e = owner(sb)
	if not e then return end
	local ss = Element.state(sb)
	local vertical = ss.data.vertical
	local g = { axis(e, vertical) }
	if not g[1] then return end
	local size, track, arrow, thumb, offset = unpack(g)
	local bg = attr(e, "SB_BACKCOLOR") or attr(e, "BACKCOLOR") or attr(e, "BGCOLOR")
	local fg = attr(e, "SB_FORECOLOR") or attr(e, "FORECOLOR") or attr(e, "FGCOLOR")
	local hl = attr(e, "SB_HIGHCOLOR") or attr(e, "HIGHCOLOR") or fg
	local press = attr(e, "SB_PRESSCOLOR") or attr(e, "PRESSCOLOR") or fg
	local state = ss.data.pressed and press or ss.data.highlight and hl or fg
	local radius = num(attr(e, "SB_CORNERRADIUS"), 0)
	local grad = attr(e, "SB_GRADIENTCOLOR")
	local direction = tostring(attr(e, "SB_GRADIENTDIRECTION") or "VERTICAL"):upper()
	local function draw_thumb()
		if vertical then
			FlatDraw.gradientBox(dc, 0, 0, st.x + 2, st.x + st.w - 3, st.y + offset, st.y + offset + thumb - 1,
				radius, state, grad, direction ~= "HORIZONTAL", bg, true)
		else
			FlatDraw.gradientBox(dc, 0, 0, st.x + offset, st.x + offset + thumb - 1, st.y + 2, st.y + st.h - 3,
				radius, state, grad, direction ~= "HORIZONTAL", bg, true)
		end
	end
	if bg and not yes(attr(e, "SHOWTRANSPARENT")) then dc:fill(st.x, st.y, st.w, st.h, bg, { radius = radius }) end
	if yes(attr(e, "SHOWTRANSPARENT")) then
		draw_thumb()
	else
		if yes(attr(e, "SHOWARROWS")) then
			if vertical then
				draw_arrow(dc, st.x, st.y, size, true, false, ss.data.highlight == "up" and hl or fg, bg)
				draw_arrow(dc, st.x, st.y + track - size, size, true, true, ss.data.highlight == "down" and hl or fg, bg)
			else
				draw_arrow(dc, st.x, st.y, size, false, false, fg, bg)
				draw_arrow(dc, st.x + track - size, st.y, size, false, true, fg, bg)
			end
		end
			draw_thumb()
	end
end

local function handler(sb, x, y)
	local e, ss = owner(sb), Element.state(sb)
	local vertical = ss.data.vertical
	local size, track, arrow, thumb, offset = axis(e, vertical)
	if not size then return nil end
	local q = vertical and y or x
	if yes(attr(e, "SHOWTRANSPARENT")) then return "drag" end
	if yes(attr(e, "SHOWARROWS")) and q < arrow then return "dec" end
	if q < offset then return "page_dec" end
	if q <= offset + thumb then return "drag" end
	if q < track - arrow then return "page_inc" end
	if yes(attr(e, "SHOWARROWS")) then return "inc" end
	return nil
end

local function scrollbar_event(sb, st, ev, rt)
	local e, ss = owner(sb), Element.state(sb)
	if not e then return false end
	local x, y = ev.lx or 0, ev.ly or 0
	if ev.type == "enter" then ss.data.highlight = handler(sb, x, y); return true end
	if ev.type == "leave" then ss.data.highlight = nil; ss.data.pressed = nil; return true end
	if ev.type == "move" then
		ss.data.highlight = handler(sb, x, y)
		if ss.data.drag then
			local g = { axis(e, ss.data.vertical) }
			local delta = (ss.data.vertical and y or x) - ss.data.drag.start
			local travel = math.max(1, g[2] - 1 - 2 * g[3] - g[4])
			local value = ss.data.drag.pos + delta * (g[6] - g[7]) / travel
			if ss.data.vertical then set_pos(e, num(attr(e, "POSX")), value, 5)
			else set_pos(e, value, num(attr(e, "POSY")), 11) end
		end
		return true
	end
	if ev.type == "press" and ev.button == 1 then
		local h = handler(sb, x, y); ss.data.pressed = h
		if h == "drag" then
			ss.data.drag = { start = ss.data.vertical and y or x, pos = num(attr(e, ss.data.vertical and "POSY" or "POSX")) }
			if rt and rt.capture then rt.capture(sb) end
		elseif h then
			local page = num(attr(e, ss.data.vertical and "DY" or "DX"))
			local line = num(attr(e, ss.data.vertical and "LINEY" or "LINEX"), page / 10)
			local amount = h == "page_inc" and page or h == "page_dec" and -page or h == "inc" and line or -line
			if ss.data.vertical then set_pos(e, num(attr(e, "POSX")), num(attr(e, "POSY")) + amount, h == "inc" and 1 or h == "dec" and 0 or h == "page_inc" and 3 or 2)
			else set_pos(e, num(attr(e, "POSX")) + amount, num(attr(e, "POSY")), h == "inc" and 7 or h == "dec" and 6 or h == "page_inc" and 9 or 8) end
		end
		return true
	end
	if ev.type == "release" and ev.button == 1 then
		ss.data.drag, ss.data.pressed = nil, nil
		if rt and rt.release then rt.release() end
		return true
	end
	return false
end

-- iupFlatScrollBarCreate makes each bar with IupCanvas: IupGetClassName says "canvas", and the
-- canvas's registrations apply to it.
local scrollbar_def = {
	name = "flatscrollbar", iupname = "canvas", children = 0, draw = scrollbar_draw, event = scrollbar_event,
	defaults = { BORDER = "NO", CANFOCUS = "NO", VISIBLE = "NO", ZORDER = "TOP" },
	callbacks = { ACTION = true, BUTTON_CB = true, MOTION_CB = true, LEAVEWINDOW_CB = true, WHEEL_CB = true },
}
Classes.define(scrollbar_def)

function M.create(e)
	local function make(vertical)
		local sb = Element.new("canvas", { BORDER = "NO", CANFOCUS = "NO", VISIBLE = "NO", ZORDER = "TOP" })
		local s = Element.state(sb)
		s.class, s.classname, s.data.vertical = scrollbar_def, "flatscrollbar", vertical
		s.data.scroll_owner = e
		return sb
	end
	local vert, horiz = make(true), make(false)
	Element.state(e).data.scrollbars = { vert, horiz }
	Element.appendInternal(e, horiz, true)
	Element.appendInternal(e, vert, true)
	M.sync(e)
	return vert, horiz
end

function M.sync(e)
	local s, bars = Element.state(e), Element.state(e).data.scrollbars
	if not bars then return end
	local size = num(attr(e, "SCROLLBARSIZE"), 15)
	local inset = num(attr(e, "SB_INSET"), 0)
	local floating = yes(attr(e, "SHOWFLOATING"))
	local vert, horiz = bars[1], bars[2]
	local vs, hs = Element.state(vert), Element.state(horiz)
	-- iupFlatScrollBarGet: FLATSCROLLBAR alone says which bars exist (YES both, HORIZONTAL,
	-- VERTICAL, else none); iFlatScrollBarSetDXAttrib/SetDYAttrib show a bar while the view
	-- is smaller than the range.
	local fsb = tostring(attr(e, "FLATSCROLLBAR") or ""):upper()
	local needv = (fsb == "YES" or fsb == "VERTICAL") and num(attr(e, "YMAX")) > num(attr(e, "DY"))
	local needh = (fsb == "YES" or fsb == "HORIZONTAL") and num(attr(e, "XMAX")) > num(attr(e, "DX"))
	Element.setAttribute(vert, "VISIBLE", needv and (floating and "NO" or "YES") or "NO")
	Element.setAttribute(horiz, "VISIBLE", needh and (floating and "NO" or "YES") or "NO")
	if floating then return end
	if needv then
		vs.x, vs.y, vs.w, vs.h = s.x + s.w - size - (inset > 0 and 2 or 0), s.y + inset,
			size, math.max(0, s.h - 2 * inset - (needh and size or 0))
	end
	if needh then
		hs.x, hs.y, hs.w, hs.h = s.x + inset, s.y + s.h - size - (inset > 0 and 2 or 0),
			math.max(0, s.w - 2 * inset - (needv and size or 0)), size
	end
end

function M.set_pos(e, x, y) set_pos(e, x, y, nil) end
function M.user_child(e) return Element.userChildren(e)[1] end
function M.visible_children(e, st)
	local out = {}
	for _, child in ipairs(st.children) do if not Element.state(child).internal then out[#out + 1] = child end end
	for _, child in ipairs(st.children) do if Element.state(child).internal then out[#out + 1] = child end end
	return out
end
function M.on_wheel(e, dy)
	if tostring(attr(e, "ORIENTATION") or ""):upper() == "HORIZONTAL" then
		local old = num(attr(e, "POSX"))
		set_pos(e, old - dy * num(attr(e, "LINEX"), 24), num(attr(e, "POSY")), dy > 0 and 6 or 7)
		return old ~= num(attr(e, "POSX"))
	end
	local old = num(attr(e, "POSY"))
	set_pos(e, num(attr(e, "POSX")), old - dy * num(attr(e, "LINEY"), 24), dy > 0 and 0 or 1)
	return old ~= num(attr(e, "POSY"))
end
return M
