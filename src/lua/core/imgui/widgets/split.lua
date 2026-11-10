-- IUP split, including its internal flatseparator sash.
-- @module core.imgui.widgets.split
local Classes = require("core.imgui.Classes")
local Element = require("core.imgui.Element")
local iup = require("core.imgui.iup")
require("core.imgui.widgets.flatseparator")

local floor, max, min = math.floor, math.max, math.min

local function attr(e, name) return Element.getAttribute(e, name) end
local function own(e, name) return Element.own(e, name) end
local function bool(v) return tostring(v or "NO"):upper() == "YES" end
local function vertical(e) return tostring(attr(e, "ORIENTATION") or "VERTICAL"):upper() ~= "HORIZONTAL" end
local function users(e) return Element.userChildren(e) end
local function num(v, default) return tonumber(v) or default end

local function bounds(s)
	local lo, hi = tostring(s.data.minmax or "0:1000"):match("^%s*(-?%d+)%s*:%s*(-?%d+)%s*$")
	lo, hi = num(lo, 0), num(hi, 1000)
	if lo > hi then lo, hi = hi, lo end
	return max(0, lo), min(1000, hi)
end

local function adjust(s)
	local lo, hi = bounds(s)
	if s.data.val ~= nil and s.data.val >= 0 then s.data.val = min(hi, max(lo, s.data.val)) end
end

local function pane_min(child, horizontal, L)
	if not child or tostring(attr(child, "FLOATING") or ""):upper() == "IGNORE" then return 0 end
	if L.minContent then return max(0, L.minContent(child, horizontal)) end
	local value = attr(child, "MINSIZE")
	local w, h = tostring(value or ""):match("^%s*(%d*)x(%d*)%s*$")
	return horizontal and num(w, 0) or num(h, 0)
end

local function hide_child(child, hide)
	if not child then return end
	if hide then
		if tostring(attr(child, "VISIBLE") or "YES"):upper() == "YES" then
			Element.setAttribute(child, "FLOATING", "IGNORE")
			Element.setAttribute(child, "VISIBLE", "NO")
		end
	elseif tostring(attr(child, "VISIBLE") or "YES"):upper() ~= "YES" then
		Element.setAttribute(child, "FLOATING", "NO")
		Element.setAttribute(child, "VISIBLE", "YES")
	end
end

local function auto_hide(e, s)
	if not s.data.autohide then return end
	local axis = vertical(e) and s.w or s.h
	local bar = s.data.barsize
	local tolerance = axis <= bar and 50 or (axis > 0 and floor(1000 * bar / axis) or 0)
	local kids = users(e)
	hide_child(kids[1], s.data.val <= tolerance)
	hide_child(kids[2], s.data.val >= 1000 - tolerance)
end

local function natural(e, s, L)
	local kids = users(e)
	local a, b = kids[1], kids[2]
	local aw, ah = a and L.natural(a) or 0, a and select(2, L.natural(a)) or 0
	local bw, bh = b and L.natural(b) or 0, b and select(2, L.natural(b)) or 0
	local bar = s.data.barsize
	local w, h
	if vertical(e) then w, h = aw + bar + bw, max(ah, bh)
	else w, h = max(aw, bw), ah + bar + bh end
	if s.data.val == -1 then
		local total = (vertical(e) and (w - bar) or (h - bar))
		s.data.val = a and total > 0 and floor(((vertical(e) and aw or ah) * 1000) / total) or bounds(s)
		if s.data.val ~= nil and s.data.val >= 0 then adjust(s) end
	end
	return w, h
end

local function set_rect(child, L, x, y, w, h)
	if not child or tostring(attr(child, "FLOATING") or ""):upper() == "IGNORE" then return end
	if L.set then L.set(child, x, y, w, h) else L.place(child, x, y, w, h) end
end

local function place(e, s, L)
	local kids = users(e)
	local bar = max(0, s.data.barsize)
	local total = max(0, (vertical(e) and s.w or s.h) - bar)
	local first = floor(total * s.data.val / 1000 + 0.5)
	local c1 = pane_min(kids[1], vertical(e), L)
	local c2 = pane_min(kids[2], vertical(e), L)
	first = max(c1, min(first, max(c1, total - c2)))
	s.data.first, s.data.total = first, total
	auto_hide(e, s)

	local bar_el = s.children[1]
	if vertical(e) then
		set_rect(kids[1], L, s.x, s.y, first, s.h)
		set_rect(bar_el, L, s.x + first, s.y, bar, s.h)
		set_rect(kids[2], L, s.x + first + bar, s.y, total - first, s.h)
	else
		set_rect(kids[1], L, s.x, s.y, s.w, first)
		set_rect(bar_el, L, s.x, s.y + first, s.w, bar)
		set_rect(kids[2], L, s.x, s.y + first + bar, s.w, total - first)
	end
	if bar_el then Element.setAttribute(bar_el, "ZORDER", "TOP") end
end

local function drag_event(e, s, ev, rt)
	local axis_pos = vertical(e) and ev.x or ev.y
	if ev.type == "press" and ev.button == 1 then
		s.data.drag = { start = axis_pos, value = s.data.val }
		if rt.capture then rt.capture(s.children[1]) end
		return true
	elseif ev.type == "move" and s.data.drag then
		local d = s.data.drag
		local value = d.value + (axis_pos - d.start) * 1000 / max(1, s.data.total)
		local lo, hi = bounds(s)
		local old = s.data.val
		s.data.val = floor(min(hi, max(lo, value)) + 0.5)
		if old ~= s.data.val then
			Element.call(e, "VALUECHANGED_CB")
			if bool(attr(e, "LAYOUTDRAG")) and rt.relayout then rt.relayout(e) end
			if not bool(attr(e, "LAYOUTDRAG")) then
				local first = floor(s.data.total * s.data.val / 1000 + 0.5)
				local bar_st = Element.state(s.children[1])
				if vertical(e) then bar_st.x = s.x + first else bar_st.y = s.y + first end
			end
		end
		return true
	elseif ev.type == "release" and s.data.drag then
		s.data.drag = nil
		if rt.release then rt.release() end
		return true
	end
	return false
end

local function create(e, s)
	local pending = s.data
	local bar = Element.new("flatseparator", {
		ORIENTATION = "VERTICAL", STYLE = "GRIP", EXPAND = "NO",
		CURSOR = "SPLITTER_VERT", BARSIZE = "5",
	})
	Element.appendInternal(e, bar, true)
	local bs = Element.state(bar)
	bs.data.split = e
	Element.set(bar, "BUTTON_CB", function() end)
	Element.set(bar, "MOTION_CB", function() end)
	s.data = {
		barsize = pending.barsize or 5, val = pending.val == nil and 500 or pending.val,
		minmax = pending.minmax or "0:1000", layoutdrag = pending.layoutdrag == nil and true or pending.layoutdrag,
		autohide = pending.autohide or false, showgrip = pending.showgrip or 1,
		orientation = pending.orientation or "VERTICAL",
	}
	adjust(s)
	Element.setAttribute(bar, "BARSIZE", tostring(s.data.barsize))
	Element.setAttribute(bar, "ORIENTATION", s.data.orientation)
	Element.setAttribute(bar, "CURSOR", s.data.orientation == "HORIZONTAL" and "SPLITTER_HORIZ" or "SPLITTER_VERT")
	Element.setAttribute(bar, "STYLE", s.data.showgrip == 3 and "SASH" or s.data.showgrip == 2 and "DUALLINES" or "GRIP")
end

local function set_orientation(e, s, value)
	s.data.orientation = tostring(value or "VERTICAL"):upper() == "HORIZONTAL" and "HORIZONTAL" or "VERTICAL"
	local bar = s.children[1]
	if bar then
		Element.setAttribute(bar, "ORIENTATION", s.data.orientation)
		Element.setAttribute(bar, "CURSOR", s.data.orientation == "HORIZONTAL" and "SPLITTER_HORIZ" or "SPLITTER_VERT")
	end
	return false
end

local function set_value(e, s, value)
	s.data.val = value == nil and -1 or num(value, s.data.val)
	if s.data.val ~= nil and s.data.val >= 0 then adjust(s) end
	return false
end

local function set_minmax(e, s, value)
	s.data.minmax = tostring(value or "0:1000")
	if s.data.val ~= nil and s.data.val >= 0 then adjust(s) end
	return false
end

local function set_barsize(e, s, value)
	s.data.barsize = max(0, num(value, 5))
	local bar = s.children[1]
	if bar then Element.setAttribute(bar, "BARSIZE", tostring(s.data.barsize)) end
	if s.data.barsize == 0 and bar then Element.setAttribute(bar, "VISIBLE", "NO")
	elseif bar then Element.setAttribute(bar, "VISIBLE", nil) end
	if s.data.val ~= nil then adjust(s) end
	return false
end

local function set_showgrip(e, s, value)
	local v = tostring(value or "YES"):upper()
	s.data.showgrip = v == "SASH" and 3 or (v == "LINES" and 2 or (bool(v) and 1 or 0))
	local bar = s.children[1]
	if bar then Element.setAttribute(bar, "STYLE", s.data.showgrip == 3 and "SASH" or s.data.showgrip == 2 and "DUALLINES" or s.data.showgrip == 1 and "GRIP" or "FILL") end
	if s.data.showgrip == 0 and s.data.barsize == 5 then set_barsize(e, s, "3") end
	return false
end

local function set_color(e, s, value)
	local bar = s.children[1]
	if bar then Element.setAttribute(bar, "COLOR", value) end
	if s.data.showgrip == 0 and bar then Element.setAttribute(bar, "STYLE", "FILL") end
	return false
end

local function set_hlcolor(e, s, value)
	local bar = s.children[1]
	if bar then Element.setAttribute(bar, "HLCOLOR", value) end
	return false
end

local function child_added(e, s, child)
	local count = #users(e)
	if count > 2 then Element.detach(child) end
end

Classes.define{
	name = "split", children = -1, create = create, childAdded = child_added,
	natural = natural, place = place, focusable = false,
	defaults = { VALUE = "500", MINMAX = "0:1000", BARSIZE = "5", COLOR = "160 160 160",
		SHOWGRIP = "YES", LAYOUTDRAG = "YES", AUTOHIDE = "NO", ORIENTATION = "VERTICAL" },
	get = {
		VALUE = function(e, s) return tostring(s.data.val) end,
		MINMAX = function(e, s) return s.data.minmax end,
		BARSIZE = function(e, s) return tostring(s.data.barsize) end,
		ORIENTATION = function(e, s) return s.data.orientation end,
		DIRECTION = function(e, s) return s.data.orientation end,
		LAYOUTDRAG = function(e, s) return s.data.layoutdrag and "YES" or "NO" end,
		AUTOHIDE = function(e, s) return s.data.autohide and "YES" or "NO" end,
		SHOWGRIP = function(e, s) return ({ [0] = "NO", [1] = "YES", [2] = "LINES", [3] = "SASH" })[s.data.showgrip] end,
		COLOR = function(e) return Element.getAttribute(Element.state(e).children[1], "COLOR") end,
		HLCOLOR = function(e) return Element.getAttribute(Element.state(e).children[1], "HLCOLOR") end,
	},
	set = {
		ORIENTATION = set_orientation, DIRECTION = set_orientation, VALUE = set_value,
		MINMAX = set_minmax, BARSIZE = set_barsize, SHOWGRIP = set_showgrip,
		COLOR = set_color, HLCOLOR = set_hlcolor,
		LAYOUTDRAG = function(e, s, v) s.data.layoutdrag = bool(v); return false end,
		AUTOHIDE = function(e, s, v) s.data.autohide = bool(v); if s.data.val ~= nil and s.data.val >= 0 then adjust(s) end; return false end,
		VISIBLE = function(e, s)
			if s.children[1] and s.data.barsize ~= 0 then Element.setAttribute(s.children[1], "VISIBLE", nil) end
			return true
		end,
	},
	callbacks = { VALUECHANGED_CB = true },
	event = function(e, s, ev, rt) return drag_event(e, s, ev, rt) end,
}

return Classes
