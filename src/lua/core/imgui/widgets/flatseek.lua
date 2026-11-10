--- Port of Lunar's IupFlatSeek (iup-fork patch 0022, src/iup_flatseek.c): a seek bar. A thin
-- line with a tall hit area. A drag shows the new place at once and commits on release, and a
-- playback tick arriving during a drag does not move the line.
--
-- C function -> Lua (same names): seek_parse, seek_track, seek_x, seek_value_at,
-- seek_redraw (draw), seek_changing, seek_commit, seek_button, seek_motion, seek_leave,
-- seek_step, seek_key, seek_focus, seek_set_value, seek_get_value, seek_set_max,
-- seek_get_max, seek_set_buffered, seek_set_marks, seek_get_accessible, seek_post (the frame
-- repaints), seek_size (natural), seek_destroy, seek_create (create), iupFlatSeekNewClass.
-- @module core.imgui.widgets.flatseek
local Classes = require("core.imgui.Classes")
local Element = require("core.imgui.Element")
local iup = require("core.imgui.iup")
local U = require("core.imgui.widgets.rawutil")

local M = {}

local SEEK_KNOB = 6
local idiv = U.idiv
local function init_data(d)
	d._init = true
	d.value, d.max, d.hover_x, d.dragging, d.focused = 0, 0, -1, false, false
	d.buffered, d.marks = {}, {}
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

-- "10-20,35,90-95": a list of ranges and points, in the same unit as VALUE. Text after a
-- colon names the mark for the caller; the bar draws a range or a point the same either way.
local function strtod(s, i)
	local num = s:match("^%s*[%+%-]?%d*%.?%d+[eE][%+%-]?%d+", i) or s:match("^%s*[%+%-]?%d*%.?%d+", i)
		or s:match("^%s*[%+%-]?%d+%.?", i)
	if not num then return nil, i end
	return tonumber((num:gsub("^%s+", ""))), i + #num
end
local function seek_parse(value)
	local list = {}
	if not value or value == "" then return list end
	local p, n = 1, #value
	while p <= n do
		local from, e = strtod(value, p)
		if not from then break end
		p = e
		local to = from
		if value:sub(p, p) == "-" then
			local t, e2 = strtod(value, p + 1)
			if t then to = t; p = e2 end
		end
		while p <= n and value:sub(p, p) ~= "," and value:sub(p, p) ~= ";" do p = p + 1 end
		if p <= n then p = p + 1 end
		list[#list + 1] = { from = from, to = to }
	end
	return list
end

local function seek_track(ih)
	local left, right = SEEK_KNOB + 1, Element.state(ih).w - SEEK_KNOB - 2
	if right <= left then right = left + 1 end
	return left, right
end
local function seek_x(ih, value)
	local left, right = seek_track(ih)
	local max = D(ih).max
	if max <= 0 then return left end
	if value < 0 then value = 0 end
	if value > max then value = max end
	return left + math.floor((right - left) * (value / max) + 0.5)
end
local function seek_value_at(ih, x)
	local left, right = seek_track(ih)
	if x < left then x = left end
	if x > right then x = right end
	return D(ih).max * (x - left) / (right - left)
end

local function seek_redraw(ih, st, dc)
	local d = D(ih)
	local ox, oy, w, h = st.x, st.y, st.w, st.h
	local active = U.bool(ih, "ACTIVE")
	local lively = d.hover_x >= 0 or d.dragging
	local thick = U.int(ih, "THICKNESS") + (lively and 2 or 0)
	local bgname = U.attr(ih, "BGCOLOR")
	local played = U.attr(ih, "PSCOLOR")
	local markname = U.attr(ih, "MARKCOLOR")
	local bg = U.strcolor(bgname, U.rgba(255, 255, 255, 255))
	local track = U.strcolor(U.attr(ih, "TRACKCOLOR"), bg)
	local buffered = U.strcolor(U.attr(ih, "BUFFERCOLOR"), track)
	local fill = U.strcolor(played, track)
	local mark = U.strcolor(markname, fill)
	U.fill(dc, ox, oy, 0, 0, w - 1, h - 1, bg)
	local left, right = seek_track(ih)
	local top = idiv(h - thick, 2)
	local bottom = top + thick - 1
	U.fill(dc, ox, oy, left, top, right, bottom, track)
	for _, r in ipairs(d.buffered) do
		U.fill(dc, ox, oy, seek_x(ih, r.from), top, seek_x(ih, r.to), bottom, buffered)
	end
	for _, r in ipairs(d.marks) do
		if r.to > r.from then U.fill(dc, ox, oy, seek_x(ih, r.from), top, seek_x(ih, r.to), bottom, mark) end
	end
	local x = seek_x(ih, d.value)
	if d.max > 0 then U.fill(dc, ox, oy, left, top, x, bottom, fill) end
	for _, r in ipairs(d.marks) do
		if r.to <= r.from then
			local tick = seek_x(ih, r.from)
			U.fill(dc, ox, oy, tick, top - 2, tick + 1, bottom + 2, mark)
		end
	end
	if d.hover_x >= 0 and not d.dragging then
		U.fill(dc, ox, oy, d.hover_x, top - 3, d.hover_x, bottom + 3, fill)
	end
	if d.max > 0 and active then -- the playhead stays, so the place reads without hovering
		-- iupFlatDrawDrawCircle(dc, x, h/2, SEEK_KNOB, filled, 1, played, bgname, 1)
		local c = U.strcolor(played, nil)
		if c then dc:circle(ox + x + 0.5, oy + idiv(h, 2) + 0.5, SEEK_KNOB, c, { filled = true }) end
	end
	if d.focused and U.int(ih, "FOCUSFEEDBACK") ~= 0 then
		local c = U.strcolor(played, nil)
		local r = SEEK_KNOB + 2 < idiv(h, 2) and SEEK_KNOB + 2 or SEEK_KNOB
		if c then dc:circle(ox + x + 0.5, oy + idiv(h, 2) + 0.5, r, c, { thickness = 1 }) end
	end
end

local function seek_changing(ih) U.call(ih, "VALUECHANGING_CB", D(ih).value) end
local function seek_commit(ih) U.call(ih, "SEEK_CB", D(ih).value) end
local function seek_button(ih, button, pressed, x, rt)
	local d = D(ih)
	if button ~= iup.BUTTON1 or d.max <= 0 then return iup.DEFAULT end
	if pressed then
		if U.bool(ih, "CANFOCUS") and rt and rt.setFocus then rt.setFocus(ih) end
		d.dragging = true
		d.value = seek_value_at(ih, x)
		seek_changing(ih)
		if rt and rt.capture then rt.capture(ih) end
	elseif d.dragging then
		d.dragging = false
		seek_commit(ih)
		if rt and rt.release then rt.release() end
	end
	redraw(ih)
	return iup.DEFAULT
end
local function seek_motion(ih, x)
	local d = D(ih)
	if x == d.hover_x then return iup.DEFAULT end
	d.hover_x = x
	if d.max > 0 then U.call(ih, "HOVER_CB", seek_value_at(ih, x), x) end
	if d.dragging then
		d.value = seek_value_at(ih, x)
		seek_changing(ih)
	end
	redraw(ih)
	return iup.DEFAULT
end
local function seek_leave(ih)
	D(ih).hover_x = -1
	U.call(ih, "HOVER_CB", 0, -1)
	redraw(ih)
	return iup.DEFAULT
end
local function seek_step(ih, by)
	local d = D(ih)
	d.value = d.value + by
	if d.value < 0 then d.value = 0 end
	if d.value > d.max then d.value = d.max end
	seek_commit(ih)
	redraw(ih)
	return iup.IGNORE
end
local function seek_key(ih, c)
	local d = D(ih)
	local base, ctrl = iup.XkeyBase(c), iup.isCtrlXkey(c)
	local step, page = tonumber(U.attr(ih, "STEP")) or 0, tonumber(U.attr(ih, "PAGESTEP")) or 0
	if d.max <= 0 then return iup.CONTINUE end
	if base == iup.K_LEFT or base == iup.K_DOWN then return seek_step(ih, ctrl and -page or -step)
	elseif base == iup.K_RIGHT or base == iup.K_UP then return seek_step(ih, ctrl and page or step)
	elseif base == iup.K_PGDN then return seek_step(ih, -page)
	elseif base == iup.K_PGUP then return seek_step(ih, page)
	elseif base == iup.K_HOME then return seek_step(ih, -d.value)
	elseif base == iup.K_END then return seek_step(ih, d.max - d.value) end
	return iup.CONTINUE
end

-- iupStrReturnDouble: "%.18g"-like, without trailing noise
local function dstr(v)
	if v == math.floor(v) and math.abs(v) < 2 ^ 53 then return string.format("%d", v) end
	return string.format("%.17g", v)
end

local function seek_event(ih, st, ev, rt)
	if ev.type == "press" or ev.type == "release" then
		seek_button(ih, ev.button == 1 and iup.BUTTON1 or ev.button == 2 and iup.BUTTON2 or iup.BUTTON3,
			ev.type == "press", ev.lx, rt)
		return true
	elseif ev.type == "move" or ev.type == "enter" then seek_motion(ih, ev.lx); return true
	elseif ev.type == "leave" then seek_leave(ih); return true
	elseif ev.type == "focus" then D(ih).focused = true; redraw(ih); return true
	elseif ev.type == "blur" then D(ih).focused = false; redraw(ih); return true
	elseif ev.type == "key" then return seek_key(ih, ev.key or 0) == iup.IGNORE
	end
	return false
end

Classes.define{
	name = "flatseek", children = 0, focusable = true,
	expandDefault = "HORIZONTAL", -- seek_create Create: IupSetAttribute(ih, "EXPAND", "HORIZONTAL")
	defaults = {
		BORDER = "NO", VALUE = "0", MAX = "0", STEP = "5", PAGESTEP = "30", THICKNESS = "2", FOCUSFEEDBACK = "YES",
		EXPAND = "HORIZONTAL", -- seek_create
	},
	callbacks = { SEEK_CB = true, VALUECHANGING_CB = true, HOVER_CB = true },
	create = function(ih, st) D(ih) end,
	natural = function() return 240, 24 end,
	draw = seek_redraw,
	event = seek_event,
	set = {
		VALUE = function(ih, st, value)
			local d = D(ih)
			if d.dragging then return false end
			local v = tonumber(value) or 0
			d.value = v < 0 and 0 or v > d.max and d.max or v
			return false
		end,
		MAX = function(ih, st, value)
			local d = D(ih)
			local v = tonumber(value) or 0
			d.max = v > 0 and v or 0
			if d.value > d.max then d.value = d.max end
			return false
		end,
		BUFFERED = function(ih, st, value) D(ih).buffered = seek_parse(value) end,
		MARKS = function(ih, st, value) D(ih).marks = seek_parse(value) end,
	},
	get = {
		VALUE = function(ih) return dstr(D(ih).value) end,
		MAX = function(ih) return dstr(D(ih).max) end,
		ACCESSIBLEVALUE = function(ih)
			local d = D(ih)
			return string.format("%d of %d", math.floor(d.value), math.floor(d.max))
		end,
	},
}

M._parse = seek_parse
return M
