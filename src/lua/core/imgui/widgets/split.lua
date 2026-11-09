local Classes = require("core.imgui.Classes")
local Element = require("core.imgui.Element")
local iup = require("core.imgui.iup")

local function attr(e, n) return Element.getAttribute(e, n) end
local function own(e, n) return Element.own(e, n) end
local function num(v, d) return tonumber(v) or d or 0 end
local function vertical(e) return tostring(attr(e, "ORIENTATION") or attr(e, "DIRECTION") or "VERTICAL"):upper() == "VERTICAL" end
local function natural(e, st, L)
	local a, b = st.children[1], st.children[2]
	local aw, ah = a and L.natural(a) or 0, a and select(2, L.natural(a)) or 0
	local bw, bh = b and L.natural(b) or 0, b and select(2, L.natural(b)) or 0
	local bar = num(attr(e, "BARSIZE"), 5)
	if vertical(e) then return aw + bar + bw, math.max(ah, bh) end
	return math.max(aw, bw), ah + bar + bh
end
local function place(e, st, L)
	local bar = math.max(0, num(attr(e, "BARSIZE"), 5))
	local value = math.max(0, math.min(1000, num(own(e, "VALUE"), 500)))
	local total = (vertical(e) and st.w or st.h) - bar
	if total < 0 then total = 0 end
	local first = math.floor(total * value / 1000 + 0.5)
	local a, b = st.children[1], st.children[2]
	if vertical(e) then
		if a then L.place(a, st.x, st.y, first, st.h) end
		if b then L.place(b, st.x + first + bar, st.y, total - first, st.h) end
	else
		if a then L.place(a, st.x, st.y, st.w, first) end
		if b then L.place(b, st.x, st.y + first + bar, st.w, total - first) end
	end
	st.data.first, st.data.total = first, total
end
local function draw(e, st, dc)
	local bar = num(attr(e, "BARSIZE"), 5)
	if bar <= 0 then return end
	local hot = st.data.hot or st.data.drag
	local c = hot and (attr(e, "HLCOLOR") or attr(e, "COLOR")) or attr(e, "COLOR")
	if vertical(e) then dc:fill(st.x + st.data.first, st.y, bar, st.h, c) else dc:fill(st.x, st.y + st.data.first, st.w, bar, c) end
	if tostring(attr(e, "SHOWGRIP") or "YES"):upper() == "SASH" and hot then
		if vertical(e) then dc:line(st.x + st.data.first + bar / 2, st.y, st.x + st.data.first + bar / 2, st.y + st.h, attr(e, "HLCOLOR") or c, 1)
		else dc:line(st.x, st.y + st.data.first + bar / 2, st.x + st.w, st.y + st.data.first + bar / 2, attr(e, "HLCOLOR") or c, 1) end
	end
end
local function event(e, st, ev, rt)
	local bar = num(attr(e, "BARSIZE"), 5)
	local inbar = vertical(e) and ev.lx >= st.data.first and ev.lx <= st.data.first + bar or (not vertical(e) and ev.ly >= st.data.first and ev.ly <= st.data.first + bar)
	if ev.type == "enter" then st.data.hot = true; rt.cursor(vertical(e) and "SIZEWE" or "SIZENS"); return true end
	if ev.type == "leave" and not st.data.drag then st.data.hot = false; return true end
	if ev.type == "press" and ev.button == 1 and inbar then
		st.data.drag = { start = vertical(e) and ev.x or ev.y, value = num(own(e, "VALUE"), 500) }
		rt.capture(e); return true
	elseif ev.type == "move" and st.data.drag then
		local d = st.data.drag
		local delta = (vertical(e) and ev.x or ev.y) - d.start
		local v = d.value + delta * 1000 / math.max(1, st.data.total)
		local lo, hi = tostring(attr(e, "MINMAX") or "0:1000"):match("(-?%d+):(-?%d+)")
		v = math.max(num(lo, 0), math.min(num(hi, 1000), v))
		Element.setAttribute(e, "VALUE", tostring(math.floor(v + 0.5)))
		Element.call(e, "VALUECHANGED_CB")
		rt.relayout(e); return true
	elseif ev.type == "release" and st.data.drag then st.data.drag = nil; rt.release(); return true end
	return inbar
end
local def = {
	name = "split", children = 2, natural = natural, place = place, draw = draw, event = event, focusable = true,
	defaults = { VALUE = "500", MINMAX = "0:1000", BARSIZE = "5", COLOR = "160 160 160", SHOWGRIP = "YES", LAYOUTDRAG = "YES", AUTOHIDE = "NO", ORIENTATION = "VERTICAL" },
	get = { VALUE = function(e) return own(e, "VALUE") or "500" end, ORIENTATION = function(e) return own(e, "ORIENTATION") or own(e, "DIRECTION") or "VERTICAL" end },
	set = { VALUE = function(e, s, v) local lo, hi = tostring(attr(e, "MINMAX") or "0:1000"):match("(-?%d+):(-?%d+)"); s.data.value = math.max(num(lo, 0), math.min(num(hi, 1000), num(v, 500))); return true end },
	callbacks = { VALUECHANGED_CB = true },
}
Classes.define(def)
return Classes
