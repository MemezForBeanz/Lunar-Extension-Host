--- IupFlatFrame on the ImGui host: a port of iup_flatframe.c (IUP 3.32 + Lunar fork).
--
-- A backgroundbox with decorations: its child sits inside DECORSIZE/DECOROFFSET (the
-- frame and frame space, plus the title bar when TITLE or TITLEIMAGE make one). The
-- redraw follows iFlatFrameRedraw_CB: parent background, the (rounded/gradient)
-- background box, the (rounded, sheened) border, then the title bar.
--
-- @module core.imgui.widgets.flatframe
local Classes = require("core.imgui.Classes")
local Element = require("core.imgui.Element")
local F = require("core.imgui.widgets.flatdraw")

local own, attr, bool, int = F.own, F.attr, F.bool, F.int

local function frame_kind(e)
	local v = attr(e, "FRAME")
	if F.bool(v) then return 1 end
	if v and v:upper() == "CROSSTITLE" then return 2 end
	return 0
end

--- iFlatFrameGetTitleSize
local function title_size(e, frame)
	local hp, vp = F.intint(attr(e, "TITLEPADDING"))
	local w, h = F.iconSize(e, F.imagePosition(attr(e, "TITLEIMAGEPOSITION")), int(attr(e, "TITLEIMAGESPACING"), 2),
		hp, vp, own(e, "TITLEIMAGE"), own(e, "TITLE"))
	if frame ~= 2 and h ~= 0 and bool(attr(e, "TITLELINE")) then h = h + int(attr(e, "TITLELINEWIDTH"), 1) end
	return w, h
end

local function decor(e)
	local frame = frame_kind(e)
	local w, h, dx, dy = 0, 0, 0, 0
	if frame ~= 0 then
		local fw, fs = int(attr(e, "FRAMEWIDTH"), 1), int(attr(e, "FRAMESPACE"), 2)
		w = 2 * fw + 2 * fs
		h = w
		dx = fw + fs
		dy = dx
	end
	local _, th = title_size(e, frame)
	return w, h + th, dx, dy + th
end

local function natural(e, st, L)
	local c = st.children[1]
	local cs = c and Element.state(c)
	if not cs then return 0, 0 end
	local dw, dh = decor(e)
	return (cs.nat_w or 0) + dw, (cs.nat_h or 0) + dh, cs.expand
end

local function place(e, st, L)
	local c = st.children[1]
	if not c then return end
	local dw, dh, dx, dy = decor(e)
	local ox, oy = F.intint(own(e, "CHILDOFFSET"))
	L.place(c, st.x + ox + dx, st.y + oy + dy, math.max(0, st.w - dw), math.max(0, st.h - dh))
end

local function draw(e, st, dc)
	local x0, y0, cw, ch = st.x, st.y, st.w, st.h
	local backcolor = own(e, "BGCOLOR") or F.nativeParentBg(e)
	local frame_width = int(attr(e, "FRAMEWIDTH"), 1)
	local frame = frame_kind(e)
	local flags = F.textFlags(e, "TITLETEXTALIGNMENT", "TITLETEXTWRAP", "TITLETEXTELLIPSIS")
	local active = attr(e, "ACTIVE") ~= "NO"

	F.parentBackground(e, dc, st)
	F.boxAttrib(e, dc, x0, y0, 0, cw - 1, 0, ch - 1, backcolor, nil, true)

	local title_w, title_h = title_size(e, frame)
	if frame ~= 0 then
		local frame_top = 0
		if frame == 2 and title_h > 0 then frame_top = frame_width + math.floor(title_h / 2) end
		F.borderAttrib(e, dc, x0, y0, 0, cw - 1, frame_top, ch - 1, frame_width, attr(e, "FRAMECOLOR"), nil, active)
	else
		frame_width = 0
	end

	if title_h > 0 then
		local titleimage, title = own(e, "TITLEIMAGE"), own(e, "TITLE")
		local titlecolor = attr(e, "TITLECOLOR")
		local titlebgcolor = attr(e, "TITLEBGCOLOR")
		local align = F.halign(attr(e, "TITLEALIGNMENT"))
		local spacing = int(attr(e, "TITLEIMAGESPACING"), 2)
		local title_line = 0
		if frame ~= 2 and bool(attr(e, "TITLELINE")) then title_line = int(attr(e, "TITLELINEWIDTH"), 1) end
		local make_inactive = not active and titleimage and not own(e, "TITLEIMAGEINACTIVE")
		local hp, vp = F.intint(attr(e, "TITLEPADDING"))
		local x_off = 0
		if frame == 2 then
			align = "left"
			x_off = 6
			F.box(dc, x0, y0, frame_width + x_off - 2, frame_width + x_off + title_w + 2,
				frame_width, frame_width + title_h - 1 - title_line, backcolor, nil, true)
		elseif titlebgcolor then
			F.box(dc, x0, y0, frame_width, cw - 1 - frame_width, frame_width, frame_width + title_h - 1 - title_line, titlebgcolor, nil, true)
		end
		if frame ~= 2 and bool(attr(e, "TITLELINE")) then
			local lc = attr(e, "TITLELINECOLOR")
			for i = 0, title_line - 1 do
				F.line(dc, x0, y0, frame_width, frame_width + title_h - 1 - i, cw - 1 - frame_width, frame_width + title_h - 1 - i, lc)
			end
		end
		F.icon(e, dc, x0, y0, frame_width + x_off, frame_width, cw - 2 * frame_width, title_h - title_line,
			F.imagePosition(attr(e, "TITLEIMAGEPOSITION")), spacing, align, "top", hp, vp,
			titleimage, make_inactive, title, flags, titlecolor, backcolor, active)
	end
end

Classes.define({
	name = "flatframe",
	children = 1,
	opaque = true,
	natural = natural,
	place = place,
	draw = draw,
	get = {
		DECORSIZE = function(e) local w, h = decor(e); return string.format("%dx%d", w, h) end,
		DECOROFFSET = function(e) local _, _, dx, dy = decor(e); return string.format("%dx%d", dx, dy) end,
		BGCOLOR = function(e, st) return st.attrs.BGCOLOR or F.nativeParentBg(e) end,
	},
})

return {}
