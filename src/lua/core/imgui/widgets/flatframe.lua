-- IUP FlatFrame.
-- @module core.imgui.widgets.flatframe
local Classes = require("core.imgui.Classes")
local Element = require("core.imgui.Element")
local Flat = require("core.imgui.widgets.flatbutton")

local function attr(e, n) return Flat.attr(e, n) end
local function yes(v) return Flat.yes(v) end
local function title_size(e)
	local hp, vp = Flat.pair(attr(e, "TITLEPADDING"))
	local w, h = Flat.icon_size(e, attr(e, "TITLE"), attr(e, "TITLEIMAGE"),
		tonumber(attr(e, "TITLEIMAGESPACING")) or 2, hp, vp,
		attr(e, "TITLEIMAGEPOSITION"))
	if h > 0 and yes(attr(e, "TITLELINE")) and tostring(attr(e, "FRAME") or "YES"):upper() ~= "CROSSTITLE" then
		h = h + (tonumber(attr(e, "TITLELINEWIDTH")) or 1)
	end
	return w, h
end
local function decor(e)
	local frame = tostring(attr(e, "FRAME") or "YES"):upper()
	if frame == "NO" then return 0, title_size(e) end
	local fw, fs = tonumber(attr(e, "FRAMEWIDTH")) or 1, tonumber(attr(e, "FRAMESPACE")) or 2
	local _, th = title_size(e)
	return 2 * (fw + fs), th + 2 * (fw + fs)
end
local function natural(e, st, L)
	local child = st.children[1]
	local w, h = child and L.natural(child) or 0, child and select(2, L.natural(child)) or 0
	local dx, dy = decor(e)
	local mx, my = Flat.pair(Element.own(e, "MARGIN") or Element.own(e, "CMARGIN"))
	return w + dx + mx * 2, h + dy + my * 2
end
local function place(e, st, L)
	local c = st.children[1]
	if not c then return end
	local fw, fs = tonumber(attr(e, "FRAMEWIDTH")) or 1, tonumber(attr(e, "FRAMESPACE")) or 2
	local _, th = title_size(e)
	local mx, my = Flat.pair(Element.own(e, "MARGIN") or Element.own(e, "CMARGIN"))
	L.place(c, st.x + fw + fs + mx, st.y + fw + fs + th + my,
		math.max(0, st.w - 2 * (fw + fs) - mx * 2),
		math.max(0, st.h - 2 * (fw + fs) - th - my * 2))
end
Classes.define{
	name = "flatframe", children = 1, natural = natural, place = place,
	defaults = { ACTIVE = "YES", FRAME = "YES", FRAMEWIDTH = "1", FRAMESPACE = "2",
		FRAMECOLOR = "160 160 160", TITLELINE = "YES", TITLELINEWIDTH = "1",
		TITLEALIGNMENT = "ACENTER", TITLEIMAGESPACING = "2", TITLEPADDING = "0x0",
		TITLETEXTALIGNMENT = "ALEFT", TITLEIMAGEPOSITION = "LEFT",
		TITLECOLOR = function() return Element.globals.DLGFGCOLOR end,
		TITLELINECOLOR = function() return Element.globals.DLGFGCOLOR end,
		GRADIENTDIRECTION = "VERTICAL" },
	draw = function(e, st, dc)
		local bg = attr(e, "BGCOLOR")
		if bg then Flat.draw_box(e, dc, st.x, st.y, st.w, st.h, bg, true) end
		local fw = tonumber(attr(e, "FRAMEWIDTH")) or 1
		local frame = tostring(attr(e, "FRAME") or "YES"):upper()
		if frame ~= "NO" then
			Flat.draw_border(e, dc, st.x, st.y, st.w, st.h, attr(e, "FRAMECOLOR"), fw, yes(attr(e, "ACTIVE")))
		end
		local _, th = title_size(e)
		if th > 0 then
			local title = attr(e, "TITLE")
			local tb = attr(e, "TITLEBGCOLOR")
			if tb then dc:fill(st.x + fw, st.y + fw, st.w - fw * 2, th, tb) end
			if yes(attr(e, "TITLELINE")) and frame ~= "CROSSTITLE" then
				local lw = tonumber(attr(e, "TITLELINEWIDTH")) or 1
				dc:line(st.x + fw, st.y + fw + th - lw, st.x + st.w - fw, st.y + fw + th - lw, attr(e, "TITLELINECOLOR"), lw)
			end
			Flat.draw_icon(e, dc, st.x + fw, st.y + fw, st.w - fw * 2, th, title, attr(e, "TITLEIMAGE"), attr(e, "TITLECOLOR"), not yes(attr(e, "ACTIVE")),
				attr(e, "TITLEIMAGEPOSITION"), attr(e, "TITLETEXTALIGNMENT"), yes(attr(e, "TITLETEXTWRAP")), yes(attr(e, "TITLETEXTELLIPSIS")))
		end
	end,
}
return Classes
