--- IupFlatButton on the ImGui host: a port of iup_flatbutton.c (IUP 3.32 + Lunar fork).
--
-- The redraw (iFlatButtonRedraw_CB), natural size (iFlatButtonComputeNaturalSizeMethod)
-- and input (button, motion, enter/leave, focus, activation keys) follow the C source
-- line by line, drawing through core.imgui.widgets.flatdraw, which ports iup_draw.c.
--
-- The module also exports a few helpers other flat widgets use (icon_size, draw_icon,
-- draw_box, draw_border, pair, yes, attr, pos).
--
-- @module core.imgui.widgets.flatbutton
local Classes = require("core.imgui.Classes")
local Element = require("core.imgui.Element")
local F = require("core.imgui.widgets.flatdraw")

local M = {}
local own, attr, bool, int = F.own, F.attr, F.bool, F.int

local IGNORE, CLOSE = -1, -3

-- Helpers kept for the other widget modules ------------------------------------------------

function M.yes(v) return bool(v) end
M.attr = attr
function M.pair(v) return F.intint(v) end
function M.pos(v) return F.imagePosition(v) end

--- Natural size of an image + title block, as iupFlatDrawGetIconSize.
function M.icon_size(e, title, img, spacing, hp, vp, image_position)
	return F.iconSize(e, F.imagePosition(image_position or attr(e, "IMAGEPOSITION")), spacing or 2,
		hp or 0, vp or 0, img, (title and title ~= "") and title or nil)
end

--- Draw an image + title block in (x, y, w, h) (dialog coordinates), as iupFlatDrawIcon.
function M.draw_icon(e, dc, x, y, w, h, title, img, fg, inactive, image_position, text_alignment, text_wrap, text_ellipsis)
	local hp, vp = F.intint(attr(e, "PADDING"))
	local ha, va = F.alignment(attr(e, "ALIGNMENT"), "ACENTER", "ACENTER")
	local flags = {
		align = F.halign(text_alignment or attr(e, "TEXTALIGNMENT")),
		wrap = text_wrap == nil and bool(attr(e, "TEXTWRAP")) or text_wrap,
		ellipsis = text_ellipsis == nil and bool(attr(e, "TEXTELLIPSIS")) or text_ellipsis,
	}
	F.icon(e, dc, 0, 0, x, y, w, h, F.imagePosition(image_position or attr(e, "IMAGEPOSITION")),
		int(attr(e, "SPACING"), 2), ha, va, hp, vp, img, inactive, title, flags, fg,
		F.nativeParentBg(e), not inactive)
end

--- Fill (x, y, w, h) honouring CORNERRADIUS / GRADIENTCOLOR (iupFlatDrawBoxAttrib).
function M.draw_box(e, dc, x, y, w, h, fill, active)
	F.boxAttrib(e, dc, x, y, 0, w - 1, 0, h - 1, fill, nil, active ~= false)
end

--- Border around (x, y, w, h) honouring CORNERRADIUS / BORDERSHEENCOLOR.
function M.draw_border(e, dc, x, y, w, h, color, width, active)
	F.borderAttrib(e, dc, x, y, 0, w - 1, 0, h - 1, width or 1, color, nil, active ~= false)
end

-- IupFlatButton ---------------------------------------------------------------------------

local function data(st)
	local d = st.data
	if d.value == nil then d.value = false end
	return d
end

local function border_width(e) return int(attr(e, "BORDERWIDTH"), 1) end

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
	end
	local bw = border_width(e)
	return w + 2 * bw, h + 2 * bw
end

local function draw(e, st, dc)
	local d = data(st)
	local x0, y0, cw, ch = st.x, st.y, st.w, st.h
	local image = own(e, "IMAGE")
	local title = own(e, "TITLE")
	local active = attr(e, "ACTIVE") ~= "NO"
	local selected = d.value
	local fgcolor = attr(e, "FGCOLOR")
	local bgcolor = own(e, "BGCOLOR")   -- not inherited: NULL means the parent's
	local bgimage = own(e, "BACKIMAGE")
	local fgimage = own(e, "FRONTIMAGE")
	local flags = F.textFlags(e, "TEXTALIGNMENT", "TEXTWRAP", "TEXTELLIPSIS")
	local bw = border_width(e)
	local draw_border = bool(own(e, "SHOWBORDER"))
	local focus_feedback = bool(attr(e, "FOCUSFEEDBACK"))

	F.parentBackground(e, dc, st)

	if not bgcolor then
		if draw_border then bgcolor = F.darkerBg(e) else bgcolor = F.nativeParentBg(e) end
	end

	local pressed_look = (d.pressed and d.highlighted) or (selected and not d.highlighted)
	if pressed_look then
		local c = attr(e, "PSCOLOR")
		if c then bgcolor = c end
		c = attr(e, "TEXTPSCOLOR")
		if c then fgcolor = c end
		draw_border = true
	elseif d.highlighted then
		local c = attr(e, "HLCOLOR")
		if c then bgcolor = c end
		c = attr(e, "TEXTHLCOLOR")
		if c then fgcolor = c end
		draw_border = true
	end

	if draw_border then
		local bordercolor = attr(e, "BORDERCOLOR")
		if pressed_look then
			bordercolor = attr(e, "BORDERPSCOLOR") or bordercolor
		elseif d.highlighted then
			bordercolor = attr(e, "BORDERHLCOLOR") or bordercolor
		end
		F.borderAttrib(e, dc, x0, y0, 0, cw - 1, 0, ch - 1, bw, bordercolor, bgcolor, active)
	end

	local image_pressed = d.pressed and d.highlighted
	if selected and not d.pressed and (bgimage or image) then image_pressed = true end

	if bgimage then
		local name, fade = F.imageName(e, "BACKIMAGE", bgimage, image_pressed, d.highlighted, true)
		if bool(attr(e, "BACKIMAGEZOOM")) then
			F.image(dc, x0, y0, name, fade, bgcolor, bw, bw, cw - bw, ch - bw)
		else
			F.image(dc, x0, y0, name, fade, bgcolor, bw, bw)
		end
	else
		F.boxAttrib(e, dc, x0, y0, bw, cw - 1 - bw, bw, ch - 1 - bw, bgcolor, nil, true)
	end

	local inner = bw
	if bool(attr(e, "CANFOCUS")) and focus_feedback then inner = inner + 1 end

	local hp, vp = F.intint(attr(e, "PADDING"))
	local ha, va = F.alignment(attr(e, "ALIGNMENT"), "ACENTER", "ACENTER")
	local name, fade = F.imageName(e, "IMAGE", image, image_pressed, d.highlighted, active)
	F.icon(e, dc, x0, y0, inner, inner, cw - 2 * inner, ch - 2 * inner,
		F.imagePosition(attr(e, "IMAGEPOSITION")), int(attr(e, "SPACING"), 2), ha, va, hp, vp,
		name, fade, title, flags, fgcolor, bgcolor, active)

	if fgimage then
		local fname, ffade = F.imageName(e, "FRONTIMAGE", fgimage, image_pressed, d.highlighted, active)
		F.image(dc, x0, y0, fname, ffade, bgcolor, inner, inner)
	elseif not image and not title then
		local space = inner + 2
		F.border(dc, x0, y0, space, cw - 1 - space, space, ch - 1 - space, 1, "0 0 0", bgcolor, active)
		space = space + 1
		F.box(dc, x0, y0, space, cw - 1 - space, space, ch - 1 - space, fgcolor, bgcolor, active)
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

--- The radio a toggle button belongs to (iupRadioFindToggleParent).
local function radio_of(e)
	if bool(own(e, "IGNORERADIO")) then return nil end
	local st = Element.state(e)
	local p = st and st.parent
	while p do
		local ps = Element.state(p)
		if not ps then return nil end
		if ps.classname == "radio" then return p end
		p = ps.parent
	end
	return nil
end
M.radioOf = radio_of

local function notify(e, st, is_toggle, ev, rt)
	local d = st.data
	if Element.hasCallback(e, "FLAT_ACTION") and not d.inside_action then
		d.inside_action = true
		local r = Element.call(e, "FLAT_ACTION")
		if r == CLOSE then
			if ev then ev.result = CLOSE elseif rt and rt.exitLoop then rt.exitLoop() end
		end
		if r ~= IGNORE and Element.state(e) then d.inside_action = false end
	end
	if is_toggle and Element.state(e) then Element.call(e, "VALUECHANGED_CB") end
end

local function update_highlighted(st, x, y)
	local d = st.data
	if x < 0 or x > st.w - 1 or y < 0 or y > st.h - 1 then
		if d.highlighted then d.highlighted = false; return true end
	else
		if not d.highlighted then d.highlighted = true; return true end
	end
	return false
end

--- iFlatButtonButton_CB
local function button(e, st, ev_button, pressed, x, y, status, ev, rt)
	local r = Element.call(e, "FLAT_BUTTON_CB", 48 + ev_button, pressed and 1 or 0, x, y, status)
	if r == IGNORE then return end
	if ev_button ~= 1 then return end
	local d = data(st)
	update_highlighted(st, x, y)
	if bool(own(e, "TOGGLE")) then
		local radio = radio_of(e)
		local last_tg
		if not pressed and d.highlighted then
			if d.value then
				if not radio then d.value = false else last_tg = e end
			else
				if radio then
					local rs = Element.state(radio)
					last_tg = rs.data.flat_last_toggle
					if last_tg and last_tg ~= e and Element.state(last_tg) then
						Element.state(last_tg).data.value = false
					else
						last_tg = nil
					end
					rs.data.flat_last_toggle = e
				end
				d.value = true
			end
		end
		d.pressed = pressed
		if not pressed and d.highlighted then
			if last_tg and e ~= last_tg then notify(last_tg, Element.state(last_tg), true, ev, rt) end
			if not radio or e ~= last_tg then notify(e, st, true, ev, rt) end
		end
	else
		d.pressed = pressed
		if not pressed and d.highlighted then notify(e, st, false, ev, rt) end
	end
	if rt and rt.redraw then rt.redraw(e) end
end

local function event(e, st, ev, rt)
	local d = data(st)
	local t = ev.type
	if attr(e, "ACTIVE") == "NO" and t ~= "leave" then return false end
	if t == "enter" then
		if Element.call(e, "FLAT_ENTERWINDOW_CB", ev.lx or 0, ev.ly or 0) == IGNORE then return true end
		d.highlighted = true
		return true
	elseif t == "leave" then
		if Element.call(e, "FLAT_LEAVEWINDOW_CB") == IGNORE then return true end
		d.highlighted = false
		return true
	elseif t == "focus" or t == "blur" then
		local focus = t == "focus"
		if Element.call(e, "FLAT_FOCUS_CB", focus and 1 or 0) == IGNORE then return true end
		d.has_focus = focus
		return true
	elseif t == "move" then
		if Element.call(e, "FLAT_MOTION_CB", ev.lx, ev.ly, ev.status) == IGNORE then return true end
		if ev.status and ev.status:sub(3, 3) == "1" then update_highlighted(st, ev.lx, ev.ly) end
		return true
	elseif t == "press" or t == "release" then
		button(e, st, ev.button, t == "press", ev.lx, ev.ly, ev.status, ev, rt)
		return true
	elseif (t == "key" and (ev.key == 13 or ev.key == 32)) or (t == "char" and ev.char == " ") then
		-- iFlatButtonActivate_CB: a press and a release in the top-left corner
		local status = "          "
		button(e, st, 1, true, 0, 0, status, ev, rt)
		button(e, st, 1, false, 0, 0, status, ev, rt)
		return true
	end
	return false
end

Classes.define({
	name = "flatbutton",
	children = 0,
	focusable = true,
	callbacks = { FLAT_ACTION = true, FLAT_BUTTON_CB = true, FLAT_MOTION_CB = true, FLAT_FOCUS_CB = true,
		FLAT_ENTERWINDOW_CB = true, FLAT_LEAVEWINDOW_CB = true, VALUECHANGED_CB = true },
	natural = natural,
	draw = draw,
	event = event,
	set = {
		VALUE = function(e, st, v)
			local d = data(st)
			if not bool(own(e, "TOGGLE")) then return false end
			v = tostring(v or ""):upper()
			if v == "TOGGLE" then d.value = not d.value else d.value = (v == "ON" or v == "YES") end
			local radio = radio_of(e)
			if radio and d.value then
				local rs = Element.state(radio)
				local last = rs.data.flat_last_toggle
				if last and last ~= e and Element.state(last) then Element.state(last).data.value = false end
				rs.data.flat_last_toggle = e
			end
			return false
		end,
		SELECTED = function(e, st, v) data(st).value = bool(v); return false end,
	},
	get = {
		VALUE = function(e, st)
			if bool(own(e, "TOGGLE")) then return data(st).value and "ON" or "OFF" end
			return nil
		end,
		SELECTED = function(e, st) return data(st).value and "YES" or "NO" end,
		HIGHLIGHTED = function(e, st) return st.data.highlighted and "YES" or "NO" end,
		PRESSED = function(e, st) return st.data.pressed and "YES" or "NO" end,
		HASFOCUS = function(e, st) return st.data.has_focus and "YES" or "NO" end,
		RADIO = function(e) return radio_of(e) and "YES" or "NO" end,
		BGCOLOR = function(e, st) return st.attrs.BGCOLOR or F.nativeParentBg(e) end,
	},
})

M.draw = draw
M.natural = natural
M.event = event
return M
