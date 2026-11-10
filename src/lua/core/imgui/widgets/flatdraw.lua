--- IUP's flat-control drawing (iup_draw.c and the fork's GDI+ paths), on the draw context.
--
-- Every flat control in IUP paints through the same few functions: a box, a border, a
-- rounded/gradient box (patch 0001), a rounded border, the corner sheen (patch 0005), the
-- icon (image + text laid out together) and the text. Porting those once, with IUP's
-- inclusive pixel coordinates (xmin..xmax), keeps every control built on them where IUP
-- put it, to the pixel.
--
-- Coordinates here are IUP's: relative to the control (0..currentwidth-1), and the
-- functions take the control's origin (ox, oy) to place them in the dialog.
--
-- @module core.imgui.widgets.flatdraw
local Element = require("core.imgui.Element")
local Color = require("core.imgui.Color")
local Fonts = require("core.imgui.Fonts")
local Draw = require("core.imgui.Draw")

local M = {}

local floor, max, min, sqrt = math.floor, math.max, math.min, math.sqrt

local function own(el, name) return Element.own(el, name) end
local function attr(el, name) return Element.getAttribute(el, name) end
M.own, M.attr = own, attr

function M.bool(v)
	if v == nil then return false end
	v = tostring(v):upper()
	return v == "YES" or v == "ON" or v == "1" or v == "TRUE"
end

function M.int(v, default)
	local n = tonumber(v)
	if not n then
		if M.bool(v) then return 1 end
		return default or 0
	end
	return floor(n)
end

--- "WxH" -> w, h (IupGetIntInt).
function M.intint(v)
	if not v then return 0, 0 end
	local a, b = tostring(v):match("^%s*(-?%d*)%s*[x:,]%s*(-?%d*)")
	if not a then return tonumber(v) or 0, 0 end
	return tonumber(a) or 0, tonumber(b) or 0
end

-- Colours -------------------------------------------------------------------------------

--- iFlatDrawColorMakeInactive (patch 0005): halfway to the surface behind, or half alpha.
function M.inactive(c, bgcolor)
	local r, g, b, a = Color.unpack(c)
	local bg = bgcolor and Color.parse(bgcolor)
	if not bg then return Color.pack(r, g, b, floor(a / 2)) end
	local br, bgg, bb = Color.unpack(bg)
	return Color.pack(floor((r + br) / 2), floor((g + bgg) / 2), floor((b + bb) / 2), a)
end

local function color_of(str, bgcolor, active)
	local c = Color.parse(str)
	if not c then return nil end
	if not active then c = M.inactive(c, bgcolor) end
	return c
end
M.color = color_of

-- Primitives (inclusive coordinates) ---------------------------------------------------------

local function swap(a, b) if b < a then return b, a end return a, b end

--- iupdrvDrawRectangle FILL
function M.fillRect(dc, ox, oy, x1, y1, x2, y2, c)
	x1, x2 = swap(x1, x2)
	y1, y2 = swap(y1, y2)
	dc:fill(ox + x1, oy + y1, x2 - x1 + 1, y2 - y1 + 1, c)
end

--- iupdrvDrawRectangle STROKE, 1px
function M.strokeRect(dc, ox, oy, x1, y1, x2, y2, c)
	x1, x2 = swap(x1, x2)
	y1, y2 = swap(y1, y2)
	dc:rect(ox + x1, oy + y1, x2 - x1 + 1, y2 - y1 + 1, c, { thickness = 1 })
end

--- iupdrvDrawLine, 1px, inclusive end points
function M.line(dc, ox, oy, x1, y1, x2, y2, c)
	if y1 == y2 then
		x1, x2 = swap(x1, x2)
		dc:fill(ox + x1, oy + y1, x2 - x1 + 1, 1, c)
	elseif x1 == x2 then
		y1, y2 = swap(y1, y2)
		dc:fill(ox + x1, oy + y1, 1, y2 - y1 + 1, c)
	else
		dc:line(ox + x1 + 0.5, oy + y1 + 0.5, ox + x2 + 0.5, oy + y2 + 0.5, c, 1)
	end
end

--- iupFlatDrawBorder
function M.border(dc, ox, oy, xmin, xmax, ymin, ymax, border_width, fgcolor, bgcolor, active)
	if not fgcolor or border_width == 0 or xmin == xmax or ymin == ymax then return end
	xmin, xmax = swap(xmin, xmax)
	ymin, ymax = swap(ymin, ymax)
	local c = color_of(fgcolor, bgcolor, active)
	if not c then return end
	M.strokeRect(dc, ox, oy, xmin, ymin, xmax, ymax, c)
	while border_width > 1 do
		border_width = border_width - 1
		M.strokeRect(dc, ox, oy, xmin + border_width, ymin + border_width, xmax - border_width, ymax - border_width, c)
	end
end

--- iupFlatDrawBox
function M.box(dc, ox, oy, xmin, xmax, ymin, ymax, fgcolor, bgcolor, active)
	if not fgcolor or xmin == xmax or ymin == ymax then return end
	local c = color_of(fgcolor, bgcolor, active)
	if not c then return end
	M.fillRect(dc, ox, oy, xmin, ymin, xmax, ymax, c)
end

local function clamp_radius(radius, xmin, xmax, ymin, ymax)
	local rmax = floor(min(xmax - xmin, ymax - ymin) / 2)
	if radius < 0 then radius = 0 end
	if radius > rmax then radius = rmax end
	return radius
end

--- iupFlatDrawGradientBox through iupdrvDrawFlatRoundBox (GDI+): a rounded-rect path at
-- pixel edges (the fork's half-pixel offset), filled solid or with a linear gradient.
function M.gradientBox(dc, ox, oy, xmin, xmax, ymin, ymax, radius, color1, color2, vertical, bgcolor, active)
	if not color1 or xmin == xmax or ymin == ymax then return end
	xmin, xmax = swap(xmin, xmax)
	ymin, ymax = swap(ymin, ymax)
	radius = clamp_radius(radius, xmin, xmax, ymin, ymax)
	local c1 = color_of(color1, bgcolor, active)
	if not c1 then return end
	local has_gradient = color2 and color2 ~= ""
	local c2 = has_gradient and (color_of(color2, bgcolor, active) or c1) or c1
	local w, h = xmax - xmin + 1, ymax - ymin + 1
	if not has_gradient then
		dc:fill(ox + xmin, oy + ymin, w, h, c1, { radius = radius })
		return
	end
	dc:gradient(ox + xmin, oy + ymin, w, h, c1, c2, vertical and "VERTICAL" or "HORIZONTAL", { radius = radius })
end

--- iupFlatDrawRoundBorder through iupdrvDrawFlatRoundBorder: the stroke centred half its
-- width inside the box, its radius reduced by the same half width.
function M.roundBorder(dc, ox, oy, xmin, xmax, ymin, ymax, radius, border_width, fgcolor, bgcolor, active)
	if not fgcolor or border_width == 0 or xmin == xmax or ymin == ymax then return end
	xmin, xmax = swap(xmin, xmax)
	ymin, ymax = swap(ymin, ymax)
	radius = clamp_radius(radius, xmin, xmax, ymin, ymax)
	if radius == 0 then return M.border(dc, ox, oy, xmin, xmax, ymin, ymax, border_width, fgcolor, bgcolor, active) end
	local c = color_of(fgcolor, bgcolor, active)
	if not c then return end
	local bw = max(border_width, 1)
	-- ImGui strokes a rect half a pixel inside its bounds; give it the box the GDI+ path
	-- used (inset by half the width) widened back by that half pixel.
	local half = bw / 2
	local x, y = ox + xmin + half - 0.5, oy + ymin + half - 0.5
	local w, h = (xmax - xmin + 1) - bw + 1, (ymax - ymin + 1) - bw + 1
	local r = max(0, radius - half)
	dc:rect(x, y, w, h, c, { radius = r, thickness = bw })
end

local REACH = { 3.2, 2.4, 1.7, 1.0, 0.4 }

--- iupdrvDrawFlatCornerSheen (patch 0005): five translucent 1px passes over each corner
-- arc and a shrinking tail along both sides, so light builds up on the arc.
function M.cornerSheen(dc, ox, oy, x1, y1, x2, y2, radius, color)
	local c = Color.parse(color)
	if not c then return end
	x1, x2 = swap(x1, x2)
	y1, y2 = swap(y1, y2)
	local l, t, r, b = x1, y1, x2, y2
	local rad = radius
	if rad > (r - l) / 2 then rad = (r - l) / 2 end
	if rad > (b - t) / 2 then rad = (b - t) / 2 end
	if rad < 1 then return end
	local room_x = (r - l) / 2 - rad
	local room_y = (b - t) / 2 - rad
	local cr, cg, cb = Color.unpack(c)
	local pen = Color.pack(cr, cg, cb, 26)
	-- GDI+ pixel centres are integer coordinates; ImGui's are at +0.5.
	local X, Y = ox + 0.5, oy + 0.5
	local function arc(cx, cy, a0)
		local pts = {}
		for i = 0, 8 do
			local a = math.rad(a0 + 90 * i / 8)
			pts[#pts + 1] = { X + cx + rad * math.cos(a), Y + cy + rad * math.sin(a) }
		end
		for i = 1, #pts - 1 do dc:line(pts[i][1], pts[i][2], pts[i + 1][1], pts[i + 1][2], pen, 1) end
	end
	for i = 1, 5 do
		local tx = rad * REACH[i]
		local ty = tx
		if tx > room_x then tx = room_x end
		if ty > room_y then ty = room_y end
		arc(l + rad, t + rad, 180)
		arc(r - rad, t + rad, 270)
		arc(r - rad, b - rad, 0)
		arc(l + rad, b - rad, 90)
		dc:line(X + l + rad, Y + t, X + l + rad + tx, Y + t, pen, 1)
		dc:line(X + r - rad, Y + t, X + r - rad - tx, Y + t, pen, 1)
		dc:line(X + l + rad, Y + b, X + l + rad + tx, Y + b, pen, 1)
		dc:line(X + r - rad, Y + b, X + r - rad - tx, Y + b, pen, 1)
		dc:line(X + l, Y + t + rad, X + l, Y + t + rad + ty, pen, 1)
		dc:line(X + r, Y + t + rad, X + r, Y + t + rad + ty, pen, 1)
		dc:line(X + l, Y + b - rad, X + l, Y + b - rad - ty, pen, 1)
		dc:line(X + r, Y + b - rad, X + r, Y + b - rad - ty, pen, 1)
	end
end

--- iupFlatDrawBoxAttrib: CORNERRADIUS (inherited), GRADIENTCOLOR, GRADIENTDIRECTION.
function M.boxAttrib(el, dc, ox, oy, xmin, xmax, ymin, ymax, fillcolor, bgcolor, active)
	local radius = M.int(attr(el, "CORNERRADIUS"), 0)
	local grad = attr(el, "GRADIENTCOLOR")
	local dir = attr(el, "GRADIENTDIRECTION")
	local vertical = not (dir and dir:upper() == "HORIZONTAL")
	-- an inset fill keeps its corners concentric with the border around it
	if radius > 0 and xmin > 0 then radius = radius > xmin and radius - xmin or 0 end
	if radius > 0 or (grad and grad ~= "") then
		M.gradientBox(dc, ox, oy, xmin, xmax, ymin, ymax, radius, fillcolor, grad, vertical, bgcolor, active)
	else
		M.box(dc, ox, oy, xmin, xmax, ymin, ymax, fillcolor, bgcolor, active)
	end
end

--- iupFlatDrawBorderAttrib: rounded when CORNERRADIUS is set, with BORDERSHEENCOLOR
-- (read locally, so a frame's sheen does not reach the controls inside it).
function M.borderAttrib(el, dc, ox, oy, xmin, xmax, ymin, ymax, border_width, color, bgcolor, active)
	local radius = M.int(attr(el, "CORNERRADIUS"), 0)
	if radius > 0 then
		local sheen = own(el, "BORDERSHEENCOLOR")
		M.roundBorder(dc, ox, oy, xmin, xmax, ymin, ymax, radius, border_width, color, bgcolor, active)
		if sheen and sheen ~= "" and active and border_width > 0 then
			M.cornerSheen(dc, ox, oy, xmin, ymin, xmax, ymax, radius, sheen)
		end
	else
		M.border(dc, ox, oy, xmin, xmax, ymin, ymax, border_width, color, bgcolor, active)
	end
end

--- iupdrvDrawFocusRect: a dotted 1px rectangle.
function M.focusRect(dc, ox, oy, x1, y1, x2, y2, color)
	local c = Color.parse(color or "0 0 0") or 0xFF000000
	c = Color.alpha(c, 0.8)
	for x = x1, x2, 2 do dc:fill(ox + x, oy + y1, 1, 1, c); dc:fill(ox + x, oy + y2, 1, 1, c) end
	for y = y1, y2, 2 do dc:fill(ox + x1, oy + y, 1, 1, c); dc:fill(ox + x2, oy + y, 1, 1, c) end
end

-- Text and images --------------------------------------------------------------------------

--- The font a flat control draws text with (DRAWFONT, else FONT).
function M.font(el)
	local f = own(el, "DRAWFONT")
	return Fonts.get(f or attr(el, "FONT"))
end

--- iupDrawGetTextSize: 0x0 for an empty string, else the widest line by the line count.
function M.textSize(el, text, font)
	if text == nil or text == "" then return 0, 0 end
	font = font or M.font(el)
	return Draw.measureText(font, text)
end

local ALIGN = { ALEFT = "left", ACENTER = "center", ARIGHT = "right" }

--- iupFlatGetHorizontalAlignment / iupFlatGetVerticalAlignment ("ACENTER" by default)
function M.halign(v)
	v = v and v:upper()
	if v == "ARIGHT" then return "right" elseif v == "ALEFT" then return "left" end
	return "center"
end
function M.valign(v)
	v = v and v:upper()
	if v == "ABOTTOM" then return "bottom" elseif v == "ATOP" then return "top" end
	return "center"
end

--- ALIGNMENT "h:v" as a flat control parses it.
function M.alignment(v, default_h, default_v)
	v = v or ""
	local h, vv = v:match("^([^:]*):?(.*)$")
	return M.halign(h ~= "" and h or default_h), M.valign(vv ~= "" and vv or default_v)
end

--- iupFlatGetImagePosition
function M.imagePosition(v)
	v = v and v:upper()
	if v == "RIGHT" or v == "BOTTOM" or v == "TOP" then return v end
	return "LEFT"
end

--- iupDrawGetTextFlags: TEXTALIGNMENT (ACENTER by default), wrap, ellipsis.
function M.textFlags(el, align_name, wrap_name, ellipsis_name)
	return {
		align = M.halign(attr(el, align_name)),
		wrap = M.bool(attr(el, wrap_name)),
		ellipsis = M.bool(attr(el, ellipsis_name)),
	}
end

--- iFlatDrawText: GDI DrawText at (x, y, w, h), top aligned, each line aligned per flags.
function M.text(dc, ox, oy, x, y, w, h, str, font, flags, fgcolor, bgcolor, active)
	if not fgcolor or not str or str == "" then return end
	local c = color_of(fgcolor, bgcolor, active)
	if not c then return end
	dc:text(str, ox + x, oy + y, w, h, c, font, {
		align = flags.align, valign = "top", wrap = flags.wrap, ellipsis = flags.ellipsis and not flags.wrap,
		clip = flags.clip,
	})
end

--- iupFlatGetImageName: the image for the state (PRESS / HIGHLIGHT / INACTIVE variants),
-- and whether it must be drawn faded.
function M.imageName(el, base, value, press, highlight, active)
	if not value then return nil, false end
	if not active then
		local v = own(el, base .. "INACTIVE")
		if v then return v, false end
		return value, true
	end
	if press then
		local v = own(el, base .. "PRESS")
		if v then return v, false end
	elseif highlight then
		local v = own(el, base .. "HIGHLIGHT")
		if v then return v, false end
	end
	return value, false
end

function M.imageInfo(name)
	local img = Draw.resolveImage(name)
	if not img then return 0, 0, nil end
	local w, h = Draw.imageSize(img)
	return w, h, img
end

--- iupdrvDrawImage, no zoom when w/h are nil.
function M.image(dc, ox, oy, name, make_inactive, bgcolor, x, y, w, h)
	local iw, ih, img = M.imageInfo(name)
	if not img then return end
	dc:image(img, ox + x, oy + y, w or iw, h or ih, { inactive = make_inactive })
end

--- iupFlatDrawGetIconSize
function M.iconSize(el, img_position, spacing, horiz_padding, vert_padding, imagename, title, font, focus_room)
	local w, h
	if imagename then
		local img_w, img_h = M.imageInfo(imagename)
		if title then
			local tw, th = M.textSize(el, title, font)
			if img_position == "RIGHT" or img_position == "LEFT" then
				w, h = img_w + tw + spacing, max(img_h, th)
			else
				w, h = max(img_w, tw), img_h + th + spacing
			end
		else
			w, h = img_w, img_h
		end
	elseif title then
		w, h = M.textSize(el, title, font)
	else
		w, h = 0, 0
	end
	w = w + 2 * horiz_padding
	h = h + 2 * vert_padding
	if focus_room then w, h = w + 4, h + 4 end
	return w, h
end

local function icon_position(icon_w, icon_h, width, height, ha, va)
	local x, y
	if ha == "right" then x = icon_w - width elseif ha == "center" then x = floor((icon_w - width) / 2) else x = 0 end
	if va == "bottom" then y = icon_h - height elseif va == "center" then y = floor((icon_h - height) / 2) else y = 0 end
	return x, y
end

local function image_text_position(x, y, pos, spacing, img_w, img_h, txt_w, txt_h)
	local ix, iy, tx, ty
	if pos == "TOP" or pos == "BOTTOM" then
		if pos == "TOP" then iy, ty = y, y + img_h + spacing else iy, ty = y + txt_h + spacing, y end
		if img_w > txt_w then ix, tx = x, x + floor((img_w - txt_w) / 2)
		else ix, tx = x + floor((txt_w - img_w) / 2), x end
	else
		if pos == "RIGHT" then ix, tx = x + txt_w + spacing, x else ix, tx = x, x + img_w + spacing end
		if img_h > txt_h then iy, ty = y, y + floor((img_h - txt_h) / 2)
		else iy, ty = y + floor((txt_h - img_h) / 2), y end
	end
	return ix, iy, tx, ty
end

--- iupFlatDrawIcon: image and title laid out together inside (icon_x, icon_y, w, h),
-- clipped to it, with the padding inside the clip.
function M.icon(el, dc, ox, oy, icon_x, icon_y, icon_w, icon_h, img_position, spacing, ha, va,
                horiz_padding, vert_padding, imagename, make_inactive, title, flags, fgcolor, bgcolor, active, font)
	if icon_w <= 0 or icon_h <= 0 then return end
	dc:clip_push(ox + icon_x, oy + icon_y, icon_w, icon_h)
	icon_w = icon_w - 2 * horiz_padding
	icon_h = icon_h - 2 * vert_padding
	icon_x = icon_x + horiz_padding
	icon_y = icon_y + vert_padding
	font = font or M.font(el)
	if title == "" then title = nil end
	if imagename and M.imageInfo(imagename) == 0 then imagename = nil end
	if imagename then
		local img_w, img_h = M.imageInfo(imagename)
		if title then
			local txt_w, txt_h = M.textSize(el, title, font)
			local width, height
			if img_position == "RIGHT" or img_position == "LEFT" then
				local max_txt_w = max(0, icon_w - img_w - spacing)
				txt_w = min(max_txt_w, txt_w)
				if flags.wrap then txt_h = icon_h else txt_h = min(icon_h, txt_h) end
				width, height = img_w + txt_w + spacing, max(img_h, txt_h)
			else
				local max_txt_h = max(0, icon_h - img_h - spacing)
				txt_w = min(icon_w, txt_w)
				if flags.wrap then txt_h = max_txt_h else txt_h = min(max_txt_h, txt_h) end
				width, height = max(img_w, txt_w), img_h + txt_h + spacing
			end
			local x, y = icon_position(icon_w, icon_h, width, height, ha, va)
			local ix, iy, tx, ty = image_text_position(x, y, img_position, spacing, img_w, img_h, txt_w, txt_h)
			M.image(dc, ox, oy, imagename, make_inactive, bgcolor, icon_x + ix, icon_y + iy, img_w, img_h)
			M.text(dc, ox, oy, icon_x + tx, icon_y + ty, txt_w, txt_h, title, font, flags, fgcolor, bgcolor, active)
		else
			local x, y = icon_position(icon_w, icon_h, img_w, img_h, ha, va)
			M.image(dc, ox, oy, imagename, make_inactive, bgcolor, icon_x + x, icon_y + y, img_w, img_h)
		end
	elseif title then
		local txt_w, txt_h = M.textSize(el, title, font)
		local width = min(icon_w, txt_w)
		local height = flags.wrap and icon_h or min(icon_h, txt_h)
		local x, y = icon_position(icon_w, icon_h, width, height, ha, va)
		M.text(dc, ox, oy, icon_x + x, icon_y + y, width, height, title, font, flags, fgcolor, bgcolor, active)
	end
	dc:clip_pop()
end

--- A class with no native window (IupGetClassType "void": the boxes, fill, split...): a
-- control's native parent is above it (iupChildTreeGetNativeParent).
function M.isVoid(st) return st.class.type == "void" end

--- iupBaseNativeParentGetBgColorAttrib: BGCOLOR (or BACKGROUND) set on the nearest native
-- ancestor that has one (iupAttribGetInheritNativeParent reads only their own values; boxes
-- are not native), else DLGBGCOLOR.
function M.nativeParentBg(el)
	local st = Element.state(el)
	local p = st and st.parent
	while p do
		local ps = Element.state(p)
		if not ps then break end
		if not M.isVoid(ps) then
			local v = ps.attrs.BGCOLOR or ps.attrs.BACKGROUND
			if v then return v end
		end
		p = ps.parent
	end
	return Element.globals.DLGBGCOLOR
end

--- iupDrawParentBackground: the whole control in its native parent's colour.
function M.parentBackground(el, dc, st)
	local bg = M.nativeParentBg(el)
	if bg then dc:fill(st.x, st.y, st.w, st.h, bg) end
end

--- iupFlatGetDarkerBgColor: the parent background, darkened as IUP does for SHOWBORDER.
function M.darkerBg(el)
	local bg = Color.parse(M.nativeParentBg(el))
	if not bg then return nil end
	local r, g, b = Color.unpack(bg)
	local f = 0.9
	return Color.tostring(Color.pack(r * f, g * f, b * f))
end

return M
