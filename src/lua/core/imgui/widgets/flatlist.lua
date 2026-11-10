local Classes = require("core.imgui.Classes")
local Element = require("core.imgui.Element")
local Fonts = require("core.imgui.Fonts")
local Draw = require("core.imgui.Draw")
local iup = require("core.imgui.iup")
local FlatScrollbar = require("core.imgui.widgets.flatscrollbar")

local function attr(e, n) return Element.getAttribute(e, n) end
local function own(e, n) return Element.own(e, n) end
local function num(v, d) return tonumber(v) or d or 0 end
local function yes(v) return tostring(v or ""):upper() == "YES" end
local function pair(v)
	local a, b = tostring(v or ""):match("^%s*(-?%d*)x(-?%d*)%s*$")
	return tonumber(a), tonumber(b)
end
local function items(e)
	local out, i = {}, 1
	while true do
		local v = own(e, tostring(i))
		if v == nil then break end
		out[i] = tostring(v)
		i = i + 1
	end
	return out
end
local function selected(st, n)
	st.data.selected = st.data.selected or {}
	return st.data.selected[n] == true
end
local function count(e) return #items(e) end
local function line_metrics(e, L)
	local f = L and L.font(e) or Fonts.forElement(e)
	local cw, ch = f:charsize()
	local p = tostring(attr(e, "PADDING") or "2x2")
	local px, py = pair(p)
	return f, math.max(ch, ch + (py or 2) * 2), (px or 2) * 2
end
local function scroll_to_focus(e, st, row_h, visible)
	local n = st.data.focus or 0
	local p = st.data.posy or 0
	local top = (n - 1) * row_h
	if top < p then p = top elseif top + row_h > p + visible then p = top + row_h - visible end
	st.data.posy = math.max(0, math.min(p, math.max(0, (st.data.ymax or 0) - visible)))
end
local function set_value(e, st, value)
	local n = count(e)
	st.data.selected = {}
	if yes(attr(e, "MULTIPLE")) then
		local s = tostring(value or "")
		for i = 1, n do st.data.selected[i] = s:sub(i, i) == "+" end
		for i = 1, n do if st.data.selected[i] then st.data.focus = i; break end end
	else
		local p = num(value, 0)
		if p >= 1 and p <= n then st.data.selected[p], st.data.focus = true, p end
	end
end
local function value_string(e, st)
	local n = count(e)
	if yes(attr(e, "MULTIPLE")) then
		local s = {}
		for i = 1, n do s[i] = selected(st, i) and "+" or "-" end
		return table.concat(s)
	end
	for i = 1, n do if selected(st, i) then return i end end
	return 0
end
local function fire(e, name, i, state)
	local text = own(e, tostring(i)) or ""
	return Element.call(e, name, text, i, state)
end
local function choose(e, st, i, ev)
	local n = count(e)
	if i < 1 or i > n then return false end
	local multiple = yes(attr(e, "MULTIPLE"))
	local old = value_string(e, st)
	st.data.focus = i
	if multiple then
		if ev and ev.mods and ev.mods.shift and st.data.anchor then
			local a, b = st.data.anchor, i
			if a > b then a, b = b, a end
			for j = 1, n do st.data.selected[j] = j >= a and j <= b end
		elseif ev and ev.mods and ev.mods.ctrl then st.data.selected[i] = not selected(st, i)
		else st.data.selected[i] = true; for j = 1, n do if j ~= i then st.data.selected[j] = false end end end
		st.data.anchor = st.data.anchor or i
		local s = value_string(e, st)
		if s ~= old then
			local r = Element.call(e, "MULTISELECT_CB", s)
			if r == nil then fire(e, "FLAT_ACTION", i, selected(st, i) and 1 or 0) end
			Element.call(e, "VALUECHANGED_CB")
		end
	else
		local oldi = tonumber(old) or 0
		st.data.selected = {}; st.data.selected[i] = true
		if oldi ~= i then
			if oldi > 0 then fire(e, "FLAT_ACTION", oldi, 0) end
			local r = fire(e, "FLAT_ACTION", i, 1)
			Element.call(e, "VALUECHANGED_CB")
			if r == iup.CLOSE then return iup.CLOSE end
		end
	end
	return true
end
local function natural(e, st, L)
	local f, rh, pad = line_metrics(e, L)
	local maxw = 0
	for i, text in ipairs(items(e)) do local w = f:measure(text); maxw = math.max(maxw, w) end
	local px, py = pair(attr(e, "PADDING"))
	local lines = num(attr(e, "VISIBLELINES"), 5)
	local cols = num(attr(e, "VISIBLECOLUMNS"), 0)
	return math.max(maxw + pad, cols > 0 and cols * f:charsize() or 0), math.max(rh * math.max(1, lines) + (py or 2), rh)
end
local function place(e, st, L)
	local _, rh = line_metrics(e, L)
	st.data.row_h, st.data.ymax, st.data.dy = rh, rh * count(e), st.h
	st.data.dx = st.w
	st.data.posy = math.max(0, math.min(st.data.posy or 0, math.max(0, st.data.ymax - st.data.dy)))
	st.data.xmax, st.data.dx = st.w, st.w
	FlatScrollbar.sync(e)
end
local function draw(e, st, dc, rt)
	local f, rh = line_metrics(e)
	local bg = attr(e, "BGCOLOR")
	if bg then dc:fill(st.x, st.y, st.w, st.h, bg, { radius = num(attr(e, "CORNERRADIUS")) }) end
	local first = math.max(1, math.floor((st.data.posy or 0) / rh) + 1)
	local last = math.min(count(e), math.ceil(((st.data.posy or 0) + st.h) / rh))
	for i = first, last do
		local y = st.y + (i - 1) * rh - (st.data.posy or 0)
		local fg, ibg = attr(e, "FGCOLOR"), attr(e, "BGCOLOR")
		if own(e, "ITEMFGCOLOR" .. i) then fg = own(e, "ITEMFGCOLOR" .. i) end
		if own(e, "ITEMBGCOLOR" .. i) then ibg = own(e, "ITEMBGCOLOR" .. i) end
		if selected(st, i) then
			ibg = attr(e, "PSCOLOR") or attr(e, "HLCOLOR") or ibg
			fg = attr(e, "TEXTPSCOLOR") or fg
			local r = num(attr(e, "ITEMRADIUS"))
			dc:fill(st.x + (r > 0 and 4 or 0), y + 1, st.w - (r > 0 and 8 or 0), rh - 2, ibg, { radius = r })
			if attr(e, "ITEMMARKERCOLOR") then dc:fill(st.x + 5, y + 5, 2, math.max(1, rh - 10), attr(e, "ITEMMARKERCOLOR")) end
		else dc:fill(st.x, y, st.w, rh, ibg) end
		local tx = st.x + num(select(1, pair(attr(e, "PADDING"))), 2)
		dc:text(own(e, tostring(i)) or "", tx, y, st.w - tx + st.x, rh, fg, f, { align = attr(e, "TEXTALIGNMENT") or "ALEFT", valign = "ACENTER", ellipsis = true, clip = true })
		if selected(st, i) and st.data.focus == i and yes(attr(e, "FOCUSFEEDBACK")) then dc:rect(st.x, y, st.w, rh, attr(e, "HLCOLOR"), { thickness = 1 }) end
	end
end
local function event(e, st, ev, rt)
	local _, rh = line_metrics(e)
	if ev.type == "wheel" then
		return FlatScrollbar.on_wheel(e, ev.dy or 0)
	elseif ev.type == "press" and ev.button == 1 then
		local i = math.floor(((ev.ly or 0) + (st.data.posy or 0)) / rh) + 1
		local r = choose(e, st, i, ev)
		st.data.press = i
		return r ~= false
	elseif ev.type == "release" and ev.button == 1 and st.data.press then
		st.data.press = nil
		return true
	elseif ev.type == "dblclick" then
		local i = math.floor(((ev.ly or 0) + (st.data.posy or 0)) / rh) + 1
		Element.call(e, "DBLCLICK_CB", i, own(e, tostring(i)) or "")
		return true
	elseif ev.type == "key" then
		local k = iup.XkeyBase(ev.key or 0)
		local n, cur = count(e), st.data.focus or 1
		local next = (k == iup.K_UP and cur - 1) or (k == iup.K_DOWN and cur + 1) or (k == iup.K_HOME and 1) or (k == iup.K_END and n) or (k == iup.K_PGUP and cur - math.max(1, math.floor(st.data.dy / rh))) or (k == iup.K_PGDN and cur + math.max(1, math.floor(st.data.dy / rh)))
		if next then choose(e, st, math.max(1, math.min(n, next)), ev); scroll_to_focus(e, st, rh, st.h); rt.redraw(e); return true end
	elseif ev.type == "char" and ev.char and ev.char ~= "" then
		local c = ev.char:lower()
		for i = (st.data.focus or 0) + 1, n do if tostring(own(e, tostring(i)) or ""):sub(1, 1):lower() == c then choose(e, st, i, ev); scroll_to_focus(e, st, rh, st.h); return true end end
	end
	return false
end
local function setter(e, st, v)
	if st.data then set_value(e, st, v) end
	return false
end
local def = {
	name = "flatlist", children = 0, clip = true, visibleChildren = FlatScrollbar.visible_children, natural = natural, place = place, draw = draw, event = event, focusable = true,
	create = function(e) FlatScrollbar.create(e) end,
	defaults = { FGCOLOR = function() return Element.globals.DLGFGCOLOR end, BGCOLOR = function() return Element.globals.DLGBGCOLOR end, HLCOLOR = "TXTHLCOLOR", FOCUSFEEDBACK = "YES", PADDING = "2x2", VISIBLELINES = "5", FLATSCROLLBAR = "NO", SCROLLBARSIZE = "12", ITEMRADIUS = "0", HLCOLORALPHA = "128" },
	get = { COUNT = function(e) return count(e) end, VALUE = function(e, s) return value_string(e, s) end,
		POSY = function(e, s) return s.data.posy or 0 end, YMAX = function(e, s) return s.data.ymax or 0 end,
		DY = function(e, s) return s.data.dy or 0 end, XMAX = function(e, s) return s.data.xmax or 0 end, DX = function(e, s) return s.data.dx or 0 end },
	set = {
		VALUE = setter,
		POSY = function(e, s, v) s.data.posy = num(v); FlatScrollbar.sync(e); return false end,
		APPENDITEM = function(e, s, v) Element.setAttribute(e, tostring(count(e) + 1), v); return false end,
		REMOVEITEM = function(e, s, v) local n, k = count(e), num(v); if k > 0 and k <= n then for i = k, n - 1 do Element.setAttribute(e, tostring(i), own(e, tostring(i + 1))) end; Element.setAttribute(e, tostring(n), nil) end; return false end,
	},
	callbacks = { FLAT_ACTION = true, VALUECHANGED_CB = true, DBLCLICK_CB = true, MULTISELECT_CB = true, FLAT_BUTTON_CB = true, FLAT_MOTION_CB = true },
}
setmetatable(def.set, { __index = function(_, name)
	local pos = tostring(name):match("^INSERTITEM(%d+)$")
	if pos then
		return function(e, st, value)
			local n = count(e)
			pos = math.max(1, math.min(n + 1, tonumber(pos)))
			for i = n + 1, pos + 1, -1 do Element.setAttribute(e, tostring(i), own(e, tostring(i - 1))) end
			Element.setAttribute(e, tostring(pos), value)
			return false
		end
	end
	return nil
end })
Classes.define(def)
return Classes
