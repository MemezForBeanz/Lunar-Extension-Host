--- IupFlatLabel on the ImGui host: a port of iup_flatlabel.c (IUP 3.32 + Lunar fork).
--
-- A flat label always paints its native parent's background ("always use the parent
-- background color"), then its image and title through iupFlatDrawIcon. It is a canvas
-- underneath, so the canvas mouse callbacks (BUTTON_CB, MOTION_CB, WHEEL_CB) reach it.
--
-- @module core.imgui.widgets.flatlabel
local Classes = require("core.imgui.Classes")
local Element = require("core.imgui.Element")
local F = require("core.imgui.widgets.flatdraw")

local own, attr, bool, int = F.own, F.attr, F.bool, F.int

local function natural(e, st, L)
	local back = own(e, "BACKIMAGE")
	if bool(attr(e, "FITTOBACKIMAGE")) and back then return F.imageInfo(back) end
	local hp, vp = F.intint(attr(e, "PADDING"))
	return F.iconSize(e, F.imagePosition(attr(e, "IMAGEPOSITION")), int(attr(e, "SPACING"), 2), hp, vp,
		own(e, "IMAGE"), own(e, "TITLE"))
end

local function draw(e, st, dc)
	local x0, y0, cw, ch = st.x, st.y, st.w, st.h
	local image, title = own(e, "IMAGE"), own(e, "TITLE")
	local active = attr(e, "ACTIVE") ~= "NO"
	local fgcolor = attr(e, "FGCOLOR")
	local bgcolor = F.nativeParentBg(e)
	local bgimage, fgimage = own(e, "BACKIMAGE"), own(e, "FRONTIMAGE")
	local flags = F.textFlags(e, "TEXTALIGNMENT", "TEXTWRAP", "TEXTELLIPSIS")

	F.parentBackground(e, dc, st)
	if bgimage then
		local name, fade = F.imageName(e, "BACKIMAGE", bgimage, false, false, true)
		if bool(attr(e, "BACKIMAGEZOOM")) then F.image(dc, x0, y0, name, fade, bgcolor, 0, 0, cw, ch)
		else F.image(dc, x0, y0, name, fade, bgcolor, 0, 0) end
	else
		F.boxAttrib(e, dc, x0, y0, 0, cw - 1, 0, ch - 1, bgcolor, nil, true)
	end

	local hp, vp = F.intint(attr(e, "PADDING"))
	local ha, va = F.alignment(attr(e, "ALIGNMENT"), "ALEFT", "ACENTER")
	local name, fade = F.imageName(e, "IMAGE", image, false, false, active)
	F.icon(e, dc, x0, y0, 0, 0, cw, ch, F.imagePosition(attr(e, "IMAGEPOSITION")), int(attr(e, "SPACING"), 2),
		ha, va, hp, vp, name, fade, title, flags, fgcolor, bgcolor, active)

	if fgimage then
		local fname, ffade = F.imageName(e, "FRONTIMAGE", fgimage, false, false, active)
		F.image(dc, x0, y0, fname, ffade, bgcolor, 0, 0)
	elseif not image and not title then
		F.border(dc, x0, y0, 2, cw - 3, 2, ch - 3, 1, "0 0 0", bgcolor, active)
		F.box(dc, x0, y0, 3, cw - 4, 3, ch - 4, fgcolor, bgcolor, active)
	end
end

local IGNORE = -1

local function event(e, st, ev, rt)
	local t = ev.type
	if t == "press" or t == "release" then
		local r = Element.call(e, "FLAT_BUTTON_CB", ev.iupbutton, t == "press" and 1 or 0, ev.lx, ev.ly, ev.status)
		if r ~= IGNORE then Element.call(e, "BUTTON_CB", ev.iupbutton, t == "press" and 1 or 0, ev.lx, ev.ly, ev.status) end
		return Element.hasCallback(e, "BUTTON_CB") or Element.hasCallback(e, "FLAT_BUTTON_CB")
	elseif t == "move" then
		Element.call(e, "FLAT_MOTION_CB", ev.lx, ev.ly, ev.status)
		Element.call(e, "MOTION_CB", ev.lx, ev.ly, ev.status)
		return true
	elseif t == "wheel" then
		if Element.hasCallback(e, "WHEEL_CB") then
			Element.call(e, "WHEEL_CB", ev.dy, ev.lx, ev.ly, ev.status)
			return true
		end
		return false
	elseif t == "enter" then
		Element.call(e, "FLAT_ENTERWINDOW_CB", ev.lx or 0, ev.ly or 0)
		return true
	elseif t == "leave" then
		Element.call(e, "FLAT_LEAVEWINDOW_CB")
		return true
	end
	return false
end

Classes.define({
	name = "flatlabel",
	children = 0,
	callbacks = { BUTTON_CB = true, MOTION_CB = true, WHEEL_CB = true, FLAT_BUTTON_CB = true,
		FLAT_MOTION_CB = true, FLAT_ENTERWINDOW_CB = true, FLAT_LEAVEWINDOW_CB = true },
	natural = natural,
	draw = draw,
	event = event,
})

return {}
