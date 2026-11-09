-- IUP flat button and the small drawing helpers shared by flat controls.
-- @module core.imgui.widgets.flatbutton
local Classes = require("core.imgui.Classes")
local Element = require("core.imgui.Element")
local Fonts = require("core.imgui.Fonts")
local Draw = require("core.imgui.Draw")

local M = {}
local function attr(e, n) return Element.getAttribute(e, n) end
local function own(e, n) return Element.own(e, n) end
local function yes(v) return tostring(v or ""):upper() == "YES" or v == true end
local function pair(v)
	local a, b = tostring(v or "0x0"):match("^%s*([^xX]*)[xX]([^xX]*)")
	return tonumber(a) or 0, tonumber(b) or 0
end
local function pos(v)
	v = tostring(v or "LEFT"):upper()
	if v == "RIGHT" or v == "TOP" or v == "BOTTOM" then return v end
	return "LEFT"
end
local function align(v, fallback)
	v = tostring(v or fallback or "ACENTER"):upper()
	if v == "ALEFT" or v == "LEFT" then return "left" end
	if v == "ARIGHT" or v == "RIGHT" then return "right" end
	if v == "ATOP" or v == "TOP" then return "top" end
	if v == "ABOTTOM" or v == "BOTTOM" then return "bottom" end
	return "center"
end
local function image(v) return Draw.resolveImage(v) end
local function image_size(v)
	local i = image(v)
	return Draw.imageSize(i)
end
local function text_size(e, title)
	return Fonts.forElement(e):measure(title or "")
end

local function icon_size(e, title, img, spacing, hp, vp, image_position)
	local iw, ih = image_size(img)
	local tw, th = text_size(e, title)
	local w, h
	if iw > 0 then
		if title and title ~= "" then
			if pos(image_position or attr(e, "IMAGEPOSITION")) == "LEFT" or pos(image_position or attr(e, "IMAGEPOSITION")) == "RIGHT" then
				w, h = iw + tw + spacing, math.max(ih, th)
			else
				w, h = math.max(iw, tw), ih + th + spacing
			end
		else w, h = iw, ih end
	else w, h = tw, th end
	return w + hp * 2, h + vp * 2
end

local function draw_icon(e, dc, x, y, w, h, title, img, fg, inactive, image_position, text_alignment, text_wrap, text_ellipsis)
	local hp, vp = pair(attr(e, "PADDING"))
	local spacing = tonumber(attr(e, "SPACING")) or 2
	x, y, w, h = x + hp, y + vp, math.max(0, w - hp * 2), math.max(0, h - vp * 2)
	local iw, ih = image_size(img)
	local tw, th = text_size(e, title)
	local p = pos(image_position or attr(e, "IMAGEPOSITION"))
	local totalw, totalh = tw, th
	if iw > 0 then
		if p == "LEFT" or p == "RIGHT" then totalw, totalh = iw + tw + spacing, math.max(ih, th)
		else totalw, totalh = math.max(iw, tw), ih + th + spacing end
	end
	local ax = align(attr(e, "ALIGNMENT"), "ACENTER:ACENTER")
	local ay = align(tostring(attr(e, "ALIGNMENT") or ""):match(":(.*)$"), "ACENTER")
	local ox = ax == "left" and 0 or ax == "right" and w - totalw or (w - totalw) / 2
	local oy = ay == "top" and 0 or ay == "bottom" and h - totalh or (h - totalh) / 2
	ox, oy = math.floor(ox + 0.5), math.floor(oy + 0.5)
	local ix, iy, tx, ty
	if iw > 0 and (p == "LEFT" or p == "RIGHT") then
		ix = p == "LEFT" and ox or ox + tw + spacing
		tx = p == "LEFT" and ox + iw + spacing or ox
		iy, ty = oy + math.floor((math.max(ih, th) - ih) / 2), oy + math.floor((math.max(ih, th) - th) / 2)
	elseif iw > 0 then
		ix, tx = ox + math.floor((math.max(iw, tw) - iw) / 2), ox + math.floor((math.max(iw, tw) - tw) / 2)
		if p == "TOP" then iy, ty = oy, oy + ih + spacing else ty, iy = oy, oy + th + spacing end
	else
		tx, ty = ox, oy
	end
	if iw > 0 then dc:image(img, x + ix, y + iy, iw, ih, { inactive = inactive }) end
	if title and title ~= "" then
		local wrap = text_wrap == nil and yes(attr(e, "TEXTWRAP")) or text_wrap
		dc:text(title, x + tx, y + ty, math.max(0, w - tx), math.max(0, h - ty), fg,
			Fonts.forElement(e), { align = align(text_alignment or attr(e, "TEXTALIGNMENT"), "ALEFT"),
				valign = "top", wrap = wrap, ellipsis = text_ellipsis == nil and yes(attr(e, "TEXTELLIPSIS")) or text_ellipsis, clip = true })
	end
end

local function draw_box(e, dc, x, y, w, h, fill, active)
	local radius = tonumber(attr(e, "CORNERRADIUS")) or 0
	local grad = attr(e, "GRADIENTCOLOR")
	local direction = attr(e, "GRADIENTDIRECTION") or "VERTICAL"
	if grad then dc:gradient(x, y, w, h, fill, grad, tostring(direction):upper(), { radius = radius })
	else dc:fill(x, y, w, h, fill, { radius = radius }) end
end

local function draw_border(e, dc, x, y, w, h, color, width, active)
	if not color or width <= 0 then return end
	dc:rect(x, y, w, h, color, { radius = tonumber(attr(e, "CORNERRADIUS")) or 0, thickness = width })
	local sheen = attr(e, "BORDERSHEENCOLOR")
	if sheen and active and (tonumber(attr(e, "CORNERRADIUS")) or 0) > 0 then
		dc:line(x + 1, y + 1, x + w - 2, y + 1, sheen, 1)
	end
end

M.icon_size = icon_size
M.draw_icon = draw_icon
M.draw_box = draw_box
M.draw_border = draw_border
M.pair = pair
M.yes = yes
M.attr = attr
M.pos = pos

local function button_state(e, st)
	local active = yes(attr(e, "ACTIVE"))
	local selected = yes(st.data.value)
	local pressed = st.data.pressed and st.data.highlighted
	local bg = attr(e, "BGCOLOR")
	local fg = attr(e, "FGCOLOR")
	if pressed or (selected and not st.data.highlighted) then
		bg, fg = attr(e, "PSCOLOR") or bg, attr(e, "TEXTPSCOLOR") or fg
	elseif st.data.highlighted then
		bg, fg = attr(e, "HLCOLOR") or bg, attr(e, "TEXTHLCOLOR") or fg
	end
	return active, selected, pressed, bg, fg
end

local function button_action(e, st, rt, ev)
	if yes(attr(e, "TOGGLE")) then
		st.data.value = not st.data.value
	end
	local result = Element.call(e, "FLAT_ACTION")
	if result == require("core.imgui.iup").CLOSE then ev.result = result end
	if yes(attr(e, "TOGGLE")) then
		Element.call(e, "VALUECHANGED_CB")
	end
	if rt and rt.redraw then rt.redraw(e) end
end

local function button_event(e, st, ev, rt)
	if not yes(attr(e, "ACTIVE")) then return false end
	if ev.type == "enter" then
		st.data.highlighted = true
		if Element.call(e, "FLAT_ENTERWINDOW_CB") ~= require("core.imgui.iup").IGNORE and rt.redraw then rt.redraw(e) end
		return true
	elseif ev.type == "leave" then
		st.data.highlighted = false
		Element.call(e, "FLAT_LEAVEWINDOW_CB")
		if rt.redraw then rt.redraw(e) end
		return true
	elseif ev.type == "focus" or ev.type == "blur" then
		st.data.focus = ev.type == "focus"
		Element.call(e, "FLAT_FOCUS_CB", st.data.focus and 1 or 0)
		if rt.redraw then rt.redraw(e) end
		return true
	elseif ev.type == "move" then
		local r = Element.call(e, "FLAT_MOTION_CB", ev.lx or ev.x, ev.ly or ev.y, ev.status)
		if r ~= require("core.imgui.iup").IGNORE and ev.status and ev.status:sub(3, 3) == "1" then
			st.data.highlighted = (ev.lx or ev.x) >= 0 and (ev.ly or ev.y) >= 0 and
				(ev.lx or ev.x) < st.w and (ev.ly or ev.y) < st.h
		end
		if rt.redraw then rt.redraw(e) end
		return true
	elseif ev.type == "press" or ev.type == "release" then
		local p = ev.type == "press" and 1 or 0
		local r = Element.call(e, "FLAT_BUTTON_CB", ev.button, p, ev.lx or ev.x, ev.ly or ev.y, ev.status)
		if r ~= require("core.imgui.iup").IGNORE and ev.button == 1 then
			local was_pressed = st.data.pressed
			st.data.highlighted = (ev.lx or ev.x) >= 0 and (ev.ly or ev.y) >= 0 and
				(ev.lx or ev.x) < st.w and (ev.ly or ev.y) < st.h
			st.data.pressed = p == 1
			if p == 1 and rt.capture then rt.capture(e) end
			if p == 0 then
				if rt.release then rt.release() end
				if st.data.highlighted and was_pressed then button_action(e, st, rt, ev) end
				st.data.pressed = false
			end
			if rt.redraw then rt.redraw(e) end
		end
		return true
	elseif ev.type == "key" and (ev.key == 32 or ev.key == 13 or ev.key == 65421) then
		st.data.highlighted = true
		st.data.pressed = true
		button_action(e, st, rt, ev)
		st.data.pressed = false
		return true
	end
	return false
end

local function button_natural(e, st, L)
	local hp, vp = pair(attr(e, "PADDING"))
	local w, h
	local back = attr(e, "BACKIMAGE")
	if yes(attr(e, "FITTOBACKIMAGE")) and back then w, h = image_size(back) else w, h = icon_size(e, attr(e, "TITLE"), attr(e, "IMAGE"), tonumber(attr(e, "SPACING")) or 2, hp, vp) end
	local bw = tonumber(attr(e, "BORDERWIDTH")) or 1
	if yes(attr(e, "FOCUSFEEDBACK")) and yes(attr(e, "CANFOCUS")) then w, h = w + 4, h + 4 end
	return w + bw * 2, h + bw * 2
end

local button = {
	name = "flatbutton", children = 0, focusable = true,
	defaults = {
		BORDER = "NO", BORDERWIDTH = "1", CANFOCUS = "YES", ACTIVE = "YES",
		HLCOLOR = "220 220 220", PSCOLOR = "200 200 200", FOCUSFEEDBACK = "YES",
		SPACING = "2", PADDING = "0x0", ALIGNMENT = "ACENTER:ACENTER",
		IMAGEPOSITION = "LEFT", TEXTALIGNMENT = "ALEFT", SHOWBORDER = "NO",
		GRADIENTDIRECTION = "VERTICAL",
	},
	callbacks = { FLAT_ACTION = true, FLAT_BUTTON_CB = true, FLAT_MOTION_CB = true,
		FLAT_ENTERWINDOW_CB = true, FLAT_LEAVEWINDOW_CB = true, FLAT_FOCUS_CB = true, VALUECHANGED_CB = true },
	natural = button_natural,
	get = {
		VALUE = function(e, st) if yes(attr(e, "TOGGLE")) then return st.data.value and "YES" or "NO" end end,
		SELECTED = function(e, st) return st.data.value and "YES" or "NO" end,
		HIGHLIGHTED = function(e, st) return st.data.highlighted and "YES" or "NO" end,
		PRESSED = function(e, st) return st.data.pressed and "YES" or "NO" end,
		HASFOCUS = function(e, st) return st.data.focus and "YES" or "NO" end,
		IMAGEPOSITION = function(e) return pos(own(e, "IMAGEPOSITION") or "LEFT") end,
	},
	set = {
		VALUE = function(e, st, v)
			if yes(attr(e, "TOGGLE")) then st.data.value = yes(v) or tostring(v):upper() == "TOGGLE" and not st.data.value end
			return false
		end,
		SELECTED = function(e, st, v) st.data.value = yes(v); return false end,
	},
	event = button_event,
	draw = function(e, st, dc, rt)
		local active, _, pressed, bg, fg = button_state(e, st)
		local bw = tonumber(attr(e, "BORDERWIDTH")) or 1
		if not bg then bg = attr(e, "BGCOLOR") end
		draw_box(e, dc, st.x, st.y, st.w, st.h, bg, true)
		if yes(attr(e, "SHOWBORDER")) or pressed or st.data.highlighted then
			local bc = attr(e, "BORDERCOLOR")
			if pressed then bc = attr(e, "BORDERPSCOLOR") or bc elseif st.data.highlighted then bc = attr(e, "BORDERHLCOLOR") or bc end
			draw_border(e, dc, st.x, st.y, st.w, st.h, bc, bw, active)
		end
		local img = attr(e, "IMAGE")
		if pressed then img = attr(e, "IMAGEPRESS") or img elseif st.data.highlighted then img = attr(e, "IMAGEHIGHLIGHT") or img end
		if not active then img = attr(e, "IMAGEINACTIVE") or img end
		draw_icon(e, dc, st.x + bw, st.y + bw, st.w - bw * 2, st.h - bw * 2, attr(e, "TITLE"), img, fg, not active)
		local front = attr(e, "FRONTIMAGE")
		if front then dc:image(front, st.x + bw, st.y + bw, nil, nil, { inactive = not active }) end
		if st.data.focus and yes(attr(e, "FOCUSFEEDBACK")) then
			draw_border(e, dc, st.x + bw, st.y + bw, st.w - bw * 2, st.h - bw * 2, fg, 1, active)
		end
	end,
}
Classes.define(button)
return M
