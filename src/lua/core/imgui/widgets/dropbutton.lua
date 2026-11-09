--- IupDropButton on the ImGui host: a port of iup_dropbutton.c (IUP 3.32 + Lunar fork).
--
-- A flat button with an arrow area; pressing it shows DROPCHILD in a drop-down below the
-- button (an rt.overlay here, a popup dialog in IUP). The redraw follows
-- iDropButtonRedraw_CB through core.imgui.widgets.flatdraw.
--
-- @module core.imgui.widgets.dropbutton
local Classes = require("core.imgui.Classes")
local Element = require("core.imgui.Element")
local Layout = require("core.imgui.Layout")
local F = require("core.imgui.widgets.flatdraw")

local own, attr, bool, int = F.own, F.attr, F.bool, F.int
local IGNORE, CLOSE = -1, -3

local function data(st) return st.data end
local function border_width(e) return int(attr(e, "BORDERWIDTH"), 1) end
-- iDropButtonGetDefaultArrowSize: 24 on a high-DPI screen, else 16; padding 5
local function arrow_size(e)
	local v = own(e, "ARROWSIZE")
	if v then return int(v, 16) end
	return require("core.imgui.Fonts").dpi > 120 and 24 or 16
end
local function arrow_padding(e) return int(own(e, "ARROWPADDING"), 5) end

local function drop_child(e)
	return Element.getHandle(e, "DROPCHILD") or Element.getHandle(e, "DROPCHILD_HANDLE")
end

local function natural(e, st, L)
	local back = own(e, "BACKIMAGE")
	local w, h
	if bool(attr(e, "FITTOBACKIMAGE")) and back then
		w, h = F.imageInfo(back)
	else
		local hp, vp = F.intint(attr(e, "PADDING"))
		local focus_room = bool(attr(e, "CANFOCUS")) and bool(attr(e, "FOCUSFEEDBACK"))
		w, h = F.iconSize(e, F.imagePosition(attr(e, "IMAGEPOSITION")), int(attr(e, "SPACING"), 2), hp, vp,
			own(e, "IMAGE"), own(e, "TITLE"), nil, focus_room)
		local cols = int(attr(e, "VISIBLECOLUMNS"), 0)
		if cols > 0 then
			local ww = F.textSize(e, "WWWWWWWWWW")
			w = math.floor(cols * ww / 10) + 2 * hp
		end
		w = w + arrow_size(e)
	end
	local bw = border_width(e)
	return w + 2 * bw, h + 2 * bw
end

--- iupFlatDrawArrow (bottom-pointing), filled and stroked as IUP draws it.
local function draw_arrow(dc, ox, oy, x, y, size, color, bgcolor, active)
	local c = F.color(color, bgcolor, active)
	if not c or size <= 0 then return end
	local off1 = math.floor(size * 0.13 + 0.5)
	local off2 = math.floor(size * 0.87 + 0.5)
	local half = math.floor(size / 2)
	local pts = { ox + x + 0.5, oy + y + off1 + 0.5, ox + x + size + 0.5, oy + y + off1 + 0.5,
		ox + x + half + 0.5, oy + y + size - off1 + 0.5 }
	dc:poly(pts, c, { filled = true })
	dc:poly(pts, c, { filled = false, thickness = 1 })
end

local function draw(e, st, dc)
	local d = data(st)
	local x0, y0, cw, ch = st.x, st.y, st.w, st.h
	local image, title = own(e, "IMAGE"), own(e, "TITLE")
	local active = attr(e, "ACTIVE") ~= "NO"
	local fgcolor = attr(e, "FGCOLOR")
	local bgcolor = own(e, "BGCOLOR")
	local bgimage, fgimage = own(e, "BACKIMAGE"), own(e, "FRONTIMAGE")
	local flags = F.textFlags(e, "TEXTALIGNMENT", "TEXTWRAP", "TEXTELLIPSIS")
	local bw = border_width(e)
	local draw_border = bool(own(e, "SHOWBORDER"))
	local drop_onarrow = bool(attr(e, "DROPONARROW"))
	local arrow_active = bool(attr(e, "ARROWACTIVE"))
	local arrow_images = int(attr(e, "ARROWIMAGES"), 0)
	local focus_feedback = bool(attr(e, "FOCUSFEEDBACK"))
	local asize, apad = arrow_size(e), arrow_padding(e)

	F.parentBackground(e, dc, st)
	if not bgcolor then
		if draw_border then bgcolor = F.darkerBg(e) else bgcolor = F.nativeParentBg(e) end
	end
	if arrow_active and not active then arrow_active = false end
	if arrow_active and not drop_child(e) then arrow_active = false end

	local bg_button, bg_arrow = bgcolor, bgcolor
	local pressed_look = (d.pressed and d.highlighted) or (d.dropped and not d.highlighted)
	if pressed_look then
		local c = attr(e, "PSCOLOR")
		if c then if drop_onarrow and d.over_arrow then bg_arrow = c else bg_button = c end end
		c = attr(e, "TEXTPSCOLOR")
		if c then fgcolor = c end
		draw_border = true
	elseif d.highlighted then
		local c = attr(e, "HLCOLOR")
		if c then if drop_onarrow and d.over_arrow then bg_arrow = c else bg_button = c end end
		c = attr(e, "TEXTHLCOLOR")
		if c then fgcolor = c end
		draw_border = true
	end
	if not arrow_active then bg_arrow = bgcolor end

	if draw_border then
		local bordercolor = attr(e, "BORDERCOLOR")
		if pressed_look then bordercolor = attr(e, "BORDERPSCOLOR") or bordercolor
		elseif d.highlighted then bordercolor = attr(e, "BORDERHLCOLOR") or bordercolor end
		if drop_onarrow then
			F.border(dc, x0, y0, 0, cw - 1 - asize, 0, ch - 1, bw, bordercolor, bg_button, active)
			F.border(dc, x0, y0, cw - 1 - asize - bw, cw - 1, 0, ch - 1, bw, bordercolor, bg_arrow, active)
		else
			F.borderAttrib(e, dc, x0, y0, 0, cw - 1, 0, ch - 1, bw, bordercolor, bg_button, active)
		end
	end

	local image_pressed = d.pressed and d.highlighted
	if d.dropped and not d.pressed and (bgimage or image) then image_pressed = true end

	if bgimage then
		local name, fade = F.imageName(e, "BACKIMAGE", bgimage, image_pressed, d.highlighted, true)
		F.image(dc, x0, y0, name, fade, bgcolor, bw, bw)
	elseif drop_onarrow then
		F.box(dc, x0, y0, bw, cw - 1 - bw - asize, bw, ch - 1 - bw, bg_button, nil, true)
		F.box(dc, x0, y0, cw - 1 - asize + bw, cw - 1 - bw, bw, ch - 1 - bw, bg_arrow, nil, true)
	else
		F.boxAttrib(e, dc, x0, y0, bw, cw - 1 - bw, bw, ch - 1 - bw, bg_button, nil, true)
	end

	local inner = bw
	if bool(attr(e, "CANFOCUS")) and focus_feedback then inner = inner + 1 end

	local hp, vp = F.intint(attr(e, "PADDING"))
	local ha, va = F.alignment(attr(e, "ALIGNMENT"), "ALEFT", "ACENTER")
	local name, fade = F.imageName(e, "IMAGE", image, image_pressed, d.highlighted, active)
	F.icon(e, dc, x0, y0, inner, inner, cw - 2 * inner - asize, ch - 2 * inner,
		F.imagePosition(attr(e, "IMAGEPOSITION")), int(attr(e, "SPACING"), 2), ha, va, hp, vp,
		name, fade, title, flags, fgcolor, bg_button, active)

	if fgimage then
		local fname, ffade = F.imageName(e, "FRONTIMAGE", fgimage, image_pressed, d.highlighted, active)
		F.image(dc, x0, y0, fname, ffade, bgcolor, inner, inner)
	elseif not image and not title then
		local space = inner + 2
		F.border(dc, x0, y0, space, cw - 1 - space - asize, space, ch - 1 - space, 1, "0 0 0", bg_button, active)
		space = space + 1
		F.box(dc, x0, y0, space, cw - 1 - space - asize, space, ch - 1 - space, fgcolor, bg_button, active)
	end

	local arrow_x = cw - 1 - asize - inner + apad
	local arrow_y = math.floor((ch - asize) / 2) + apad
	local align = own(e, "ARROWALIGN")
	if align then
		align = align:upper()
		if align == "TOP" then arrow_y = apad elseif align == "BOTTOM" then arrow_y = ch - asize - apad end
	end
	if arrow_images > 0 then
		local aname, afade = F.imageName(e, "ARROWIMAGE", own(e, "ARROWIMAGE"),
			arrow_active and d.pressed, arrow_active and d.highlighted, arrow_active)
		F.image(dc, x0, y0, aname, afade, bgcolor, arrow_x, arrow_y)
	else
		draw_arrow(dc, x0, y0, arrow_x, arrow_y, asize - 2 * apad, own(e, "ARROWCOLOR") or fgcolor, bg_arrow, arrow_active)
	end

	if d.has_focus and focus_feedback then
		local fb = inner - 1
		local radius = int(attr(e, "CORNERRADIUS"), 0)
		if radius > 0 then
			F.roundBorder(dc, x0, y0, fb, cw - 1 - fb, fb, ch - 1 - fb, radius > fb and radius - fb or 1, 1, fgcolor, nil, active)
		else
			F.focusRect(dc, x0, y0, fb, fb, cw - 1 - fb, ch - 1 - fb, fgcolor)
		end
	end
end

-- The drop-down --------------------------------------------------------------------------

local function close_drop(e, st)
	local d = data(st)
	if d.overlay then
		local o = d.overlay
		d.overlay = nil
		o:close()
	end
end

local function show_drop(e, st, rt, show)
	local d = data(st)
	local child = drop_child(e)
	if not child then return end
	if not show then
		close_drop(e, st)
		return
	end
	if d.overlay then return end
	local cs = Element.state(child)
	Layout.natural(child)
	local w = math.max(cs.nat_w or 0, st.w)
	local h = cs.nat_h or 0
	-- below the button, or above it when it would leave the window
	local x, y = st.x, st.y + st.h
	local R = require("core.imgui.Runtime")
	local main = R.mainDialog() and Element.state(R.mainDialog())
	local _, oy = R.toWindow(e, 0, 0)
	if main and oy + y + h > main.h and st.y - h >= 0 then y = st.y - h end
	Layout.layout(child, x, y, w, h)
	Element.call(e, "DROPSHOW_CB", 1)
	d.overlay = rt.overlay({
		owner = e, x = x, y = y, w = w, h = h,
		draw = function(dc)
			Layout.layout(child, x, y, w, h)
			R.paint(child, dc)
		end,
		event = function(ev)
			local target = R.hitTest(child, ev.x, ev.y) or child
			if ev.type == "key" or ev.type == "char" then target = child end
			local ok = R.deliver(target, ev)
			if ev.type == "key" and ev.key == 0xFF1B then show_drop(e, st, rt, false); return true end
			return ok or ev.type == "press" or ev.type == "release" or ev.type == "move"
		end,
		closed = function()
			d.overlay = nil
			d.dropped = false
			Element.call(e, "DROPSHOW_CB", 0)
			R.redraw(e)
		end,
	})
end

local function update_highlighted(st, x, y)
	local d = data(st)
	local was = d.highlighted
	d.highlighted = not (x < 0 or x > st.w - 1 or y < 0 or y > st.h - 1)
	return was ~= d.highlighted
end

local function event(e, st, ev, rt)
	local d = data(st)
	local t = ev.type
	if attr(e, "ACTIVE") == "NO" and t ~= "leave" then return false end
	if t == "enter" then
		if Element.call(e, "FLAT_ENTERWINDOW_CB", ev.lx or 0, ev.ly or 0) ~= IGNORE then d.highlighted = true end
		return true
	elseif t == "leave" then
		if Element.call(e, "FLAT_LEAVEWINDOW_CB") ~= IGNORE then d.highlighted = false; d.over_arrow = false end
		return true
	elseif t == "focus" or t == "blur" then
		d.has_focus = t == "focus"
		Element.call(e, "FLAT_FOCUS_CB", d.has_focus and 1 or 0)
		return true
	elseif t == "move" then
		if Element.call(e, "FLAT_MOTION_CB", ev.lx, ev.ly, ev.status) == IGNORE then return true end
		d.over_arrow = ev.lx >= st.w - arrow_size(e) - border_width(e)
		if ev.status and ev.status:sub(3, 3) == "1" then update_highlighted(st, ev.lx, ev.ly) end
		return true
	elseif t == "press" or t == "release" then
		local pressed = t == "press"
		if Element.call(e, "FLAT_BUTTON_CB", ev.iupbutton, pressed and 1 or 0, ev.lx, ev.ly, ev.status) == IGNORE then return true end
		if ev.button ~= 1 then return true end
		update_highlighted(st, ev.lx, ev.ly)
		d.over_arrow = ev.lx >= st.w - arrow_size(e) - border_width(e)
		d.pressed = pressed
		if not pressed and d.highlighted then
			local onarrow = bool(attr(e, "DROPONARROW"))
			if not onarrow or d.over_arrow then
				d.dropped = not d.dropped
				local r = Element.call(e, "DROPDOWN_CB", d.dropped and 1 or 0)
				if r ~= IGNORE then show_drop(e, st, rt, d.dropped) end
			else
				local r = Element.call(e, "FLAT_ACTION")
				if r == CLOSE then ev.result = CLOSE end
			end
		end
		return true
	elseif (t == "key" and (ev.key == 13 or ev.key == 0xFF54)) or (t == "char" and ev.char == " ") then
		d.dropped = not d.dropped
		Element.call(e, "DROPDOWN_CB", d.dropped and 1 or 0)
		show_drop(e, st, rt, d.dropped)
		return true
	end
	return false
end

Classes.define({
	name = "dropbutton",
	children = 0,
	focusable = true,
	callbacks = { FLAT_ACTION = true, DROPDOWN_CB = true, DROPSHOW_CB = true, FLAT_BUTTON_CB = true,
		FLAT_MOTION_CB = true, FLAT_FOCUS_CB = true, FLAT_ENTERWINDOW_CB = true, FLAT_LEAVEWINDOW_CB = true },
	natural = natural,
	draw = draw,
	event = event,
	set = {
		SHOWDROPDOWN = function(e, st, v)
			local show = bool(v)
			st.data.dropped = show
			local R = require("core.imgui.Runtime")
			show_drop(e, st, R, show)
			return false
		end,
	},
	get = {
		SHOWDROPDOWN = function(e, st) return st.data.dropped and "YES" or "NO" end,
		HIGHLIGHTED = function(e, st) return st.data.highlighted and "YES" or "NO" end,
		PRESSED = function(e, st) return st.data.pressed and "YES" or "NO" end,
		HASFOCUS = function(e, st) return st.data.has_focus and "YES" or "NO" end,
		BGCOLOR = function(e, st) return st.attrs.BGCOLOR or F.nativeParentBg(e) end,
	},
	destroy = function(e, st) close_drop(e, st) end,
	-- iDropButtonCreateMethod: initial values, not defaults, so they can be set to NULL
	create = function(e, st)
		if st.attrs.HLCOLOR == nil then st.attrs.HLCOLOR = "200 225 245" end
		if st.attrs.PSCOLOR == nil then st.attrs.PSCOLOR = "150 200 235" end
	end,
})

return {}
