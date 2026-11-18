--- Port of Lunar's IupFlatSegmented (iup-fork patch 0020, src/iup_flatsegmented.c): a joined
-- option control, 2-5 options on one canvas.
--
-- C function -> Lua (same names): seg_count, seg_set_count, seg_get_count, seg_set_value,
-- seg_get_value, seg_redraw (draw), seg_select, seg_button, seg_left, seg_right, seg_home,
-- seg_end, seg_focus, seg_post (the frame repaints), seg_size (natural), seg_create (create),
-- iupFlatSegmentedNewClass (Classes.define).
-- @module core.imgui.widgets.flatsegmented
local Classes = require("core.imgui.Classes")
local Element = require("core.imgui.Element")
local iup = require("core.imgui.iup")
local FlatDraw = require("core.imgui.widgets.flatdraw")
local U = require("core.imgui.widgets.rawutil")

local M = {}

local idiv, atoi = U.idiv, U.atoi
local function init_data(d)
	d._init = true
	d.count, d.value, d.focused = 2, 0, false
end
-- ih->data: the class data, made on first use (IUP runs Create before any attribute)
local function D(ih)
	local d = Element.state(ih).data
	if not d._init then init_data(d) end
	return d
end
local function redraw(ih)
	local Runtime = package.loaded["core.imgui.Runtime"]
	if Runtime and Runtime.redraw then Runtime.redraw(ih) end
end

local function seg_set_count(ih, st, value)
	local d = D(ih)
	local n = value and atoi(value) or 2
	d.count = n < 2 and 2 or n > 5 and 5 or n
	if d.value >= d.count then d.value = d.count - 1 end
	redraw(ih)
	return false
end
local function seg_set_value(ih, st, value)
	local d = D(ih)
	local n = value and atoi(value) or 0
	d.value = n < 0 and 0 or n >= d.count and d.count - 1 or n
	redraw(ih)
	return false
end

local function seg_redraw(ih, st, dc)
	local d = D(ih)
	local ox, oy, w, h = st.x, st.y, st.w, st.h
	local r, active = U.int(ih, "CORNERRADIUS"), U.bool(ih, "ACTIVE")
	local bg, sel = U.attr(ih, "BGCOLOR"), U.attr(ih, "PSCOLOR")
	local border, fg = U.attr(ih, "BORDERCOLOR"), U.attr(ih, "FGCOLOR")
	local seltext, font = U.attr(ih, "TEXTPSCOLOR"), U.font(ih)
	local _, charheight = font:charsize()
	FlatDraw.parentBackground(ih, dc, st)
	if r < 1 then r = 7 end
	FlatDraw.gradientBox(dc, ox, oy, 0, w - 1, 0, h - 1, r, bg, nil, true, bg, active)
	for i = 0, d.count - 1 do
		local x1, x2 = idiv(i * w, d.count), idiv((i + 1) * w, d.count) - 1
		local title = Element.own(ih, "TITLE" .. i)
		if i == d.value then
			FlatDraw.gradientBox(dc, ox, oy, x1 + 2, x2 - 2, 2, h - 3, r - 2, sel, nil, true, bg, active)
		end
		if title then
			local c = U.strcolor((i == d.value and seltext) and seltext or fg, 0)
			U.text(dc, ox, oy, title, x1 + 3, idiv(h - charheight, 2), x2 - x1 - 5, charheight, c, font,
				U.CENTER + U.LAYOUTCENTER + U.ELLIPSIS)
		end
	end
	FlatDraw.roundBorder(dc, ox, oy, 0, w - 1, 0, h - 1, r, 1, border, bg, active)
	if d.focused and U.int(ih, "FOCUSFEEDBACK") ~= 0 then
		U.focusrect(dc, ox, oy, 2, 2, w - 3, h - 3, fg)
	end
end

local function seg_select(ih, pos)
	local d = D(ih)
	if pos < 0 then pos = 0 end
	if pos >= d.count then pos = d.count - 1 end
	if pos ~= d.value then
		d.value = pos
		U.call(ih, "VALUECHANGED_CB")
		redraw(ih)
	end
	return iup.IGNORE
end
local function seg_button(ih, button, pressed, x)
	local w = Element.state(ih).w
	if button == iup.BUTTON1 and pressed and w > 0 then return seg_select(ih, idiv(x * D(ih).count, w)) end
	return iup.DEFAULT
end
local KEYS = {
	[iup.K_LEFT] = function(ih) return seg_select(ih, D(ih).value - 1) end,
	[iup.K_UP] = function(ih) return seg_select(ih, D(ih).value - 1) end,
	[iup.K_RIGHT] = function(ih) return seg_select(ih, D(ih).value + 1) end,
	[iup.K_DOWN] = function(ih) return seg_select(ih, D(ih).value + 1) end,
	[iup.K_HOME] = function(ih) return seg_select(ih, 0) end,
	[iup.K_END] = function(ih) return seg_select(ih, D(ih).count - 1) end,
}

local function seg_event(ih, st, ev, rt)
	if ev.type == "press" or ev.type == "release" then
		seg_button(ih, ev.button == 1 and iup.BUTTON1 or ev.button == 2 and iup.BUTTON2 or iup.BUTTON3, ev.type == "press", ev.lx)
		return true
	elseif ev.type == "focus" then D(ih).focused = true; redraw(ih); return true
	elseif ev.type == "blur" then D(ih).focused = false; redraw(ih); return true
	elseif ev.type == "key" then
		local fn = KEYS[ev.key or 0]
		if fn then fn(ih); return true end
	end
	return false
end

Classes.define{
	name = "flatsegmented", children = 0, focusable = true,
	expandDefault = "NO", -- seg_create Create: IupSetAttribute(ih, "EXPAND", "NO")
	defaults = {
		BORDER = "NO", COUNT = "2", VALUEPOS = "0", CORNERRADIUS = "7", FOCUSFEEDBACK = "YES",
		EXPAND = "NO", -- seg_create
	},
	callbacks = { VALUECHANGED_CB = true },
	create = function(ih, st) D(ih) end,
	natural = function(ih) return D(ih).count * 88, 32 end,
	draw = seg_redraw,
	event = seg_event,
	set = { COUNT = seg_set_count, VALUEPOS = seg_set_value },
	get = {
		COUNT = function(ih) return D(ih).count end,
		VALUEPOS = function(ih) return D(ih).value end,
	},
}

return M
