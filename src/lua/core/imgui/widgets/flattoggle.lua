--- IupFlatToggle on the ImGui host: a port of iup_flattoggle.c with Lunar's patches
-- (0001 rounded corners and CHECKRADIUS, 0007 SWITCH).
--
-- The C keeps padding, spacing, border width, check size and check spacing in its control
-- data with these defaults (iFlatToggleCreateMethod): SPACING 2, BORDERWIDTH 1, CHECKSIZE 16
-- (24 on a high-DPI screen), CHECKSPACING 5, ALIGNMENT ACENTER:ACENTER. Here they are read
-- from the attributes with the same defaults.
--
-- @module core.imgui.widgets.flattoggle
local Classes = require("core.imgui.Classes")
local Element = require("core.imgui.Element")
local F = require("core.imgui.widgets.flatdraw")
local FlatButton = require("core.imgui.widgets.flatbutton")

local M = {}

local CLOSE, IGNORE = -3, -1
local floor = math.floor
local own, attr, bool, int = F.own, F.attr, F.bool, F.int

-- iup_flattoggle.c
local ITOGGLE_BORDER, ITOGGLE_SPACE, ITOGGLE_MARGIN = 1, 2, 2

--- iFlatToggleGetDefaultCheckSize (the host draws at 96 DPI)
local DEFAULT_CHECK_SIZE = 16

local function check_size(e) return int(attr(e, "CHECKSIZE"), DEFAULT_CHECK_SIZE) end
local function check_spacing(e) return int(attr(e, "CHECKSPACING"), 5) end
local function border_width(e) return int(attr(e, "BORDERWIDTH"), 1) end

local function data(st)
	local d = st.data
	if d.value == nil then d.value = 0 end
	return d
end

--- iFlatToggleComputeNaturalSizeMethod
local function natural(e, st, L)
	local back = own(e, "BACKIMAGE")
	local w, h
	if bool(attr(e, "FITTOBACKIMAGE")) and back then
		w, h = F.imageInfo(back)
	else
		local hp, vp = F.intint(attr(e, "PADDING"))
		-- iupFlatDrawGetIconSize leaves room for the focus feedback
		local focus_room = bool(attr(e, "CANFOCUS")) and bool(attr(e, "FOCUSFEEDBACK"))
		w, h = F.iconSize(e, F.imagePosition(attr(e, "IMAGEPOSITION")), int(attr(e, "SPACING"), 2), hp, vp,
			own(e, "IMAGE"), own(e, "TITLE"), nil, focus_room)
		local cs = check_size(e)
		if cs ~= 0 then
			w = w + cs + check_spacing(e)
			if cs > h then h = cs end
		end
	end
	local bw = border_width(e)
	return w + 2 * bw, h + 2 * bw
end

--- iFlatToggleRedraw_CB
local function draw(e, st, dc)
	local d = data(st)
	local x0, y0, cw, ch = st.x, st.y, st.w, st.h
	local image = own(e, "IMAGE")
	local title = own(e, "TITLE")
	local active = attr(e, "ACTIVE") ~= "NO"
	local selected = d.value
	local fgcolor = attr(e, "FGCOLOR")
	local bgcolor = own(e, "BGCOLOR")
	local bgimage = own(e, "BACKIMAGE")
	local fgimage = own(e, "FRONTIMAGE")
	local flags = F.textFlags(e, "TEXTALIGNMENT", "TEXTWRAP", "TEXTELLIPSIS")
	local check_at_right = int(attr(e, "CHECKRIGHT"), 0) ~= 0
	local radio = FlatButton.radioOf(e)
	local bw = border_width(e)
	local draw_border = bool(own(e, "SHOWBORDER"))
	local focus_feedback = bool(attr(e, "FOCUSFEEDBACK"))
	local cs, cspace = check_size(e), check_spacing(e)
	local icon_left, check_left, icon_width, icon_right

	F.parentBackground(e, dc, st)

	if not bgcolor then
		if draw_border then bgcolor = F.darkerBg(e) else bgcolor = F.nativeParentBg(e) end
	end

	local pressed_look = (d.pressed and d.highlighted) or (selected ~= 0 and not d.highlighted)
	if cs ~= 0 then
		check_left = 0
		icon_left = cs + cspace
		icon_right = cw - 1
		if check_at_right then
			check_left = cw - cs
			icon_left = 0
			icon_right = cw - 1 - cs - cspace
		end
		icon_width = cw - cs - cspace
	else
		if pressed_look then
			bgcolor = attr(e, "PSCOLOR") or bgcolor
			fgcolor = attr(e, "TEXTPSCOLOR") or fgcolor
			draw_border = true
		elseif d.highlighted then
			bgcolor = attr(e, "HLCOLOR") or bgcolor
			fgcolor = attr(e, "TEXTHLCOLOR") or fgcolor
			draw_border = true
		end
		check_left, icon_left, icon_right, icon_width = 0, 0, cw - 1, cw
	end

	-- draw border - can still be disabled setting border_width=0
	if draw_border then
		local bordercolor = attr(e, "BORDERCOLOR")
		if pressed_look then
			bordercolor = attr(e, "BORDERPSCOLOR") or bordercolor
		elseif d.highlighted then
			bordercolor = attr(e, "BORDERHLCOLOR") or bordercolor
		end
		F.borderAttrib(e, dc, x0, y0, 0, cw - 1, 0, ch - 1, bw, bordercolor, bgcolor, active)
	end

	-- simulate pressed when selected and has images (but colors and borders are not included)
	local image_pressed = d.pressed and d.highlighted
	if selected ~= 0 and not d.pressed and (bgimage or image) then image_pressed = true end

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

	-- Lunar fork (0007): SWITCH=YES draws a Carbon toggle switch instead of a check box.
	-- SWITCHPOS (0 to 100) lets an animation move the knob; without it the knob follows
	-- the value.
	if bool(attr(e, "SWITCH")) then
		local track_w, track_h, knob = 36, 20, 14
		local track_x = floor((cw - track_w) / 2)
		local track_y = floor((ch - track_h) / 2)
		local pos = attr(e, "SWITCHPOS") and int(attr(e, "SWITCHPOS"), 0) or (selected ~= 0 and 100 or 0)
		local knob_x = track_x + 3 + floor(pos * (track_w - knob - 6) / 100)
		local knob_y = track_y + 3
		local track_color = attr(e, pos >= 50 and "SWITCHONCOLOR" or "SWITCHOFFCOLOR")
		local knob_color = attr(e, "SWITCHKNOBCOLOR")
		-- iupFlatDrawRoundBox
		F.gradientBox(dc, x0, y0, track_x, track_x + track_w - 1, track_y, track_y + track_h - 1, floor(track_h / 2),
			track_color or fgcolor, nil, true, bgcolor, active)
		F.gradientBox(dc, x0, y0, knob_x, knob_x + knob - 1, knob_y, knob_y + knob - 1, floor(knob / 2),
			knob_color or bgcolor, nil, true, track_color or fgcolor, active)
		return
	end

	-- reserve space for focus feedback (after background draw)
	if bool(attr(e, "CANFOCUS")) and focus_feedback then bw = bw + 1 end

	local hp, vp = F.intint(attr(e, "PADDING"))
	local ha, va = F.alignment(attr(e, "ALIGNMENT"), "ACENTER", "ACENTER")
	local name, fade = F.imageName(e, "IMAGE", image, image_pressed, d.highlighted, active)
	F.icon(e, dc, x0, y0, bw + icon_left, bw, icon_width - 2 * bw, ch - 2 * bw,
		F.imagePosition(attr(e, "IMAGEPOSITION")), int(attr(e, "SPACING"), 2), ha, va, hp, vp,
		name, fade, title, flags, fgcolor, bgcolor, active)

	if fgimage then
		local fname, ffade = F.imageName(e, "FRONTIMAGE", fgimage, image_pressed, d.highlighted, active)
		F.image(dc, x0, y0, fname, ffade, bgcolor, bw, bw + icon_left)
	elseif not image and not title then
		local space = bw + ITOGGLE_MARGIN
		F.border(dc, x0, y0, space + icon_left, icon_right - space, space, ch - 1 - space, 1, "0 0 0", bgcolor, active)
		space = space + 1
		F.box(dc, x0, y0, space + icon_left, icon_right - space, space, ch - 1 - space, fgcolor, bgcolor, active)
	end

	if cs ~= 0 then
		local check_alig = F.valign(attr(e, "CHECKALIGN"))
		local xc = check_left + floor(cs / 2)
		local yc = floor(ch / 2)
		local radius = floor(cs / 2) - ITOGGLE_MARGIN
		local check_xmin = check_left + ITOGGLE_MARGIN
		local check_ymin = floor((ch - cs) / 2) + ITOGGLE_MARGIN
		local size = cs - 2 * ITOGGLE_MARGIN
		local check_image = own(e, "CHECKIMAGE")

		if check_alig == "bottom" then
			check_ymin = ch - 1 - ITOGGLE_MARGIN
			yc = ch - 1 - ITOGGLE_MARGIN - floor(cs / 2)
		elseif check_alig == "top" then
			check_ymin = ITOGGLE_MARGIN
			yc = floor(cs / 2)
		end

		if check_image then
			local draw_image, make_inactive
			if selected == -1 then
				draw_image, make_inactive = F.imageName(e, "CHECKIMAGENOTDEF", own(e, "CHECKIMAGENOTDEF"), d.pressed, d.highlighted, active)
			elseif selected ~= 0 then
				draw_image, make_inactive = F.imageName(e, "CHECKIMAGEON", own(e, "CHECKIMAGEON"), d.pressed, d.highlighted, active)
			end
			if not draw_image then
				draw_image, make_inactive = F.imageName(e, "CHECKIMAGE", check_image, d.pressed, d.highlighted, active)
			end
			F.image(dc, x0, y0, draw_image, make_inactive, bgcolor, check_xmin, check_ymin)
		else
			local check_fgcolor = own(e, "CHECKFGCOLOR") or fgcolor
			local check_bgcolor = attr(e, "CHECKBGCOLOR")
			local bordercolor = attr(e, "BORDERCOLOR")
			if pressed_look then
				local presscolor = attr(e, "CHECKPSCOLOR")
				if presscolor then
					check_fgcolor = presscolor
				elseif d.highlighted then
					check_bgcolor = attr(e, "HLCOLOR") or check_bgcolor
					check_fgcolor = bordercolor -- only when highlighted
				end
			elseif d.highlighted then
				check_fgcolor = attr(e, "CHECKHLCOLOR") or bordercolor -- only when highlighted
			end
			local check_radius = int(attr(e, "CHECKRADIUS"), 0)

			-- check background
			if radio then
				M.circle(dc, x0, y0, xc, yc, radius, true, 1, check_bgcolor, bgcolor, active)
			else
				F.gradientBox(dc, x0, y0, check_xmin, check_xmin + size, check_ymin, check_ymin + size,
					check_radius, check_bgcolor, nil, true, bgcolor, active)
			end
			-- check border
			if radio then
				M.circle(dc, x0, y0, xc, yc, radius, false, ITOGGLE_BORDER, check_fgcolor, bgcolor, active)
			else
				F.roundBorder(dc, x0, y0, check_xmin, check_xmin + size, check_ymin, check_ymin + size,
					check_radius, ITOGGLE_BORDER, check_fgcolor, bgcolor, active)
			end
			-- check mark
			if selected ~= 0 then
				local inset = ITOGGLE_SPACE + ITOGGLE_BORDER
				if radio then
					M.circle(dc, x0, y0, xc, yc, radius - inset, true, 1, check_fgcolor, check_bgcolor, active)
				elseif selected == -1 then
					F.box(dc, x0, y0, check_xmin + inset, check_xmin + size - inset,
						check_ymin + inset, check_ymin + size - inset, check_fgcolor, check_bgcolor, active)
				else
					M.checkMark(dc, x0, y0, check_xmin + inset, check_xmin + size - inset,
						check_ymin + inset, check_ymin + size - inset, check_fgcolor, check_bgcolor, active)
				end
			end
		end
	end

	if d.has_focus and focus_feedback then
		local fb = bw - 1
		-- Lunar fork: rounded controls get a focus ring along the contour (see iup_flatbutton.c).
		local focus_radius = int(attr(e, "CORNERRADIUS"), 0)
		if focus_radius > 0 then
			F.roundBorder(dc, x0, y0, fb + icon_left, icon_right - fb, fb, ch - 1 - fb,
				focus_radius > fb and focus_radius - fb or 1, 1, fgcolor, nil, active)
		else
			F.focusRect(dc, x0, y0, fb + icon_left, fb, icon_right - fb, ch - 1 - fb, fgcolor)
		end
	end
end

--- iupFlatDrawDrawCircle: iupdrvDrawArc over (xc-r, yc-r)..(xc+r, yc+r)
function M.circle(dc, ox, oy, xc, yc, radius, fill, line_width, fgcolor, bgcolor, active)
	local c = F.color(fgcolor, bgcolor, active)
	if not c then return end
	dc:circle(ox + xc + 0.5, oy + yc + 0.5, radius, c, { filled = fill, thickness = line_width })
end

--- iupFlatDrawCheckMark: an open two-segment polyline, 2 px wide (Polyline in the driver)
function M.checkMark(dc, ox, oy, xmin, xmax, ymin, ymax, color, bgcolor, active)
	local c = F.color(color, bgcolor, active)
	if not c then return end
	local x1, y1 = ox + xmin + 0.5, oy + floor((ymax + ymin) / 2) + 0.5
	local x2, y2 = ox + floor((xmax + xmin) / 2) + 0.5, oy + ymax + 0.5
	local x3, y3 = ox + xmax + 0.5, oy + ymin + 0.5
	dc:line(x1, y1, x2, y2, c, 2)
	dc:line(x2, y2, x3, y3, c, 2)
end

--- iFlatToggleNotify
local function notify(e, rt, ev)
	local d = Element.state(e).data
	local r = Element.call(e, "FLAT_ACTION", d.value)
	if r == CLOSE then
		if ev then ev.result = CLOSE elseif rt and rt.exitLoop then rt.exitLoop() end
	end
	if Element.state(e) then Element.call(e, "VALUECHANGED_CB") end
end

--- iFlatToggleUpdateHighlighted
local function update_highlighted(st, x, y)
	local d = st.data
	if x < 0 or x > st.w - 1 or y < 0 or y > st.h - 1 then
		if d.highlighted then d.highlighted = false; return true end
	else
		if not d.highlighted then d.highlighted = true; return true end
	end
	return false
end

local function last_toggle(radio)
	local rs = radio and Element.state(radio)
	local last = rs and rs.data.flat_last_toggle
	if last and Element.state(last) then return last end
	return nil
end

local function set_last_toggle(radio, e)
	local rs = Element.state(radio)
	if rs then rs.data.flat_last_toggle = e end
end

--- iFlatToggleButton_CB
local function button(e, st, ev_button, pressed, x, y, status, ev, rt)
	if Element.call(e, "FLAT_BUTTON_CB", 48 + ev_button, pressed and 1 or 0, x, y, status) == IGNORE then return end
	if ev_button ~= 1 then return end
	local d = data(st)
	local radio = FlatButton.radioOf(e)
	local last_tg
	update_highlighted(st, x, y)
	if not pressed and d.highlighted then -- released inside the button area
		local selected = d.value
		if selected > 0 then -- was ON
			if not radio then
				d.value = int(attr(e, "3STATE"), 0) ~= 0 and -1 or 0
			else
				last_tg = e -- to avoid the callback call
			end
		elseif selected == -1 then
			d.value = 0
		else -- was OFF
			if radio then
				last_tg = last_toggle(radio)
				if last_tg and last_tg ~= e then
					data(Element.state(last_tg)).value = 0
					if rt and rt.redraw then rt.redraw(last_tg) end
				else
					last_tg = nil
				end
				set_last_toggle(radio, e)
			end
			d.value = 1
		end
	end
	d.pressed = pressed
	if rt and rt.redraw then rt.redraw(e) end
	if not pressed and d.highlighted then
		if last_tg and e ~= last_tg then notify(last_tg, rt, ev) end
		if not radio or e ~= last_tg then notify(e, rt, ev) end
		if radio and e == last_tg and bool(own(e, "SELECTEDNOTIFY")) then notify(e, rt, ev) end
	end
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
		if t == "press" and rt and rt.capture then rt.capture(e) end
		button(e, st, ev.button, t == "press", ev.lx, ev.ly, ev.status, ev, rt)
		return true
	elseif (t == "key" and (ev.key == 13 or ev.key == 32)) or (t == "char" and ev.char == " ") then
		-- iFlatToggleActivate_CB (K_CR, K_SP): a press and a release in the top-left corner
		local status = "          "
		button(e, st, 1, true, 0, 0, status, ev, rt)
		button(e, st, 1, false, 0, 0, status, ev, rt)
		return true
	end
	return false
end

--- iFlatToggleSetValueAttrib
local function set_value(e, st, value)
	local d = data(st)
	local radio = FlatButton.radioOf(e)
	if radio then
		-- can only set Radio to ON
		if bool(value) then
			local last = last_toggle(radio)
			if last and last ~= e then data(Element.state(last)).value = 0 end
			set_last_toggle(radio, e)
			d.value = 1
		end
		return false
	end
	local v = tostring(value or ""):upper()
	if v == "TOGGLE" then
		d.value = d.value ~= 0 and 0 or 1
	elseif int(attr(e, "3STATE"), 0) ~= 0 and v == "NOTDEF" then
		d.value = -1
	else
		d.value = bool(value) and 1 or 0
	end
	return false
end

Classes.define({
	name = "flattoggle",
	children = 0,
	focusable = function(e) return attr(e, "CANFOCUS") ~= "NO" end,
	callbacks = { FLAT_ACTION = true, FLAT_BUTTON_CB = true, FLAT_MOTION_CB = true, FLAT_FOCUS_CB = true,
		FLAT_ENTERWINDOW_CB = true, FLAT_LEAVEWINDOW_CB = true, VALUECHANGED_CB = true },
	natural = natural,
	draw = draw,
	event = event,
	-- iFlatToggleCreateMethod: initial values, not defaults, so they can be set to NULL
	create = function(e, st)
		data(st)
		if st.attrs.HLCOLOR == nil then st.attrs.HLCOLOR = "200 225 245" end
		if st.attrs.PSCOLOR == nil then st.attrs.PSCOLOR = "150 200 235" end
	end,
	--- iFlatToggleMapMethod: the first toggle mapped in a radio is its value
	map = function(e, st)
		local radio = FlatButton.radioOf(e)
		if radio and not last_toggle(radio) then
			data(st).value = 1
			set_last_toggle(radio, e)
		end
	end,
	set = {
		VALUE = set_value,
	},
	get = {
		-- iupStrReturnChecked
		VALUE = function(e, st)
			local v = data(st).value
			return v == -1 and "NOTDEF" or (v ~= 0 and "ON" or "OFF")
		end,
		RADIO = function(e) return FlatButton.radioOf(e) and "YES" or "NO" end,
		HIGHLIGHTED = function(e, st) return st.data.highlighted and "YES" or "NO" end,
		PRESSED = function(e, st) return st.data.pressed and "YES" or "NO" end,
		HASFOCUS = function(e, st) return st.data.has_focus and "YES" or "NO" end,
		BGCOLOR = function(e, st) return st.attrs.BGCOLOR or F.nativeParentBg(e) end,
	},
})

M.natural = natural
M.draw = draw
M.event = event
return M
