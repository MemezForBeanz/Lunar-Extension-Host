-- IUP FlatLabel.
-- @module core.imgui.widgets.flatlabel
local Classes = require("core.imgui.Classes")
local Element = require("core.imgui.Element")
local Flat = require("core.imgui.widgets.flatbutton")

local function yes(v) return Flat.yes(v) end

-- Boxes are not windows in IUP: a control's "native parent" is the nearest ancestor that is.
local VOID = { hbox = true, vbox = true, zbox = true, fill = true, cbox = true, gridbox = true,
	normalizer = true, radio = true, sbox = true, user = true, spacer = true }

--- iupBaseNativeParentGetBgColorAttrib: the background of the window the control sits in.
local function native_parent_bg(e)
	local st = Element.state(e)
	local p = st and st.parent
	while p do
		local ps = Element.state(p)
		if not ps then break end
		if not VOID[ps.classname] then return Element.getAttribute(p, "BGCOLOR") end
		p = ps.parent
	end
	return Element.globals.DLGBGCOLOR
end
local function attr(e, n) return Flat.attr(e, n) end
local function label_natural(e, st, L)
	local hp, vp = Flat.pair(attr(e, "PADDING"))
	return Flat.icon_size(e, attr(e, "TITLE"), attr(e, "IMAGE"), tonumber(attr(e, "SPACING")) or 2, hp, vp)
end
local function event(e, st, ev, rt)
	if ev.type == "enter" then st.data.highlighted = true; Element.call(e, "FLAT_ENTERWINDOW_CB"); if rt.redraw then rt.redraw(e) end; return true end
	if ev.type == "leave" then st.data.highlighted = false; Element.call(e, "FLAT_LEAVEWINDOW_CB"); if rt.redraw then rt.redraw(e) end; return true end
	if ev.type == "move" then Element.call(e, "FLAT_MOTION_CB", ev.lx or ev.x, ev.ly or ev.y, ev.status); return true end
	return false
end
Classes.define{
	name = "flatlabel", children = 0,
	defaults = { ACTIVE = "YES", SPACING = "2", PADDING = "0x0", ALIGNMENT = "ALEFT:ACENTER",
		IMAGEPOSITION = "LEFT", TEXTALIGNMENT = "ALEFT", GRADIENTDIRECTION = "VERTICAL" },
	callbacks = { FLAT_BUTTON_CB = true, FLAT_MOTION_CB = true, FLAT_ENTERWINDOW_CB = true, FLAT_LEAVEWINDOW_CB = true },
	get = { IMAGEPOSITION = function(e) return Flat.pos(Element.own(e, "IMAGEPOSITION") or "LEFT") end },
	natural = label_natural,
	event = event,
	draw = function(e, st, dc)
		-- iup_flatlabel.c: "always use the parent background color"
		local bg = native_parent_bg(e)
		if bg then dc:fill(st.x, st.y, st.w, st.h, bg) end
		local img = attr(e, "IMAGE")
		if not yes(attr(e, "ACTIVE")) then img = attr(e, "IMAGEINACTIVE") or img end
		Flat.draw_icon(e, dc, st.x, st.y, st.w, st.h, attr(e, "TITLE"), img, attr(e, "FGCOLOR"), not yes(attr(e, "ACTIVE")))
		local front = attr(e, "FRONTIMAGE")
		if front then dc:image(front, st.x, st.y, nil, nil, { inactive = not yes(attr(e, "ACTIVE")) }) end
	end,
}
return Classes
