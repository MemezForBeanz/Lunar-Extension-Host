-- IUP FlatSeparator, including Lunar's sash style.
-- @module core.imgui.widgets.flatseparator
local Classes = require("core.imgui.Classes")
local Element = require("core.imgui.Element")
local iup = require("core.imgui.iup")
local Flat = require("core.imgui.widgets.flatbutton")
local Color = require("core.imgui.Color")

local function attr(e, n) return Flat.attr(e, n) end
local function style(e) return tostring(Element.own(e, "STYLE") or "SUNKENLINE"):upper() end
local function horiz(e) return tostring(Element.own(e, "ORIENTATION") or "VERTICAL"):upper() == "HORIZONTAL" end
local function natural(e)
	local n = tonumber(Element.own(e, "BARSIZE")) or 5
	return horiz(e) and 0 or n, horiz(e) and n or 0
end
local function event(e, st, ev, rt)
	local owner = st.data.split
	if owner then
		local split = require("core.imgui.Classes").get("split")
		if ev.type == "enter" then
			st.data.hot = true
			if rt.cursor then rt.cursor(horiz(e) and "SIZENS" or "SIZEWE") end
			if rt.redraw then rt.redraw(e) end
			return true
		elseif ev.type == "leave" then
			if not Element.state(owner).data.drag then st.data.hot = false end
			if rt.redraw then rt.redraw(e) end
			return true
		elseif ev.type == "move" then
			Element.call(e, "MOTION_CB", ev.lx or ev.x, ev.ly or ev.y, ev.status)
			return split.event(owner, Element.state(owner), ev, rt)
		elseif ev.type == "press" or ev.type == "release" then
			local pressed = ev.type == "press" and 1 or 0
			local result = Element.call(e, "BUTTON_CB", ev.iupbutton or (iup.BUTTON1 + (ev.button or 1) - 1),
				pressed, ev.lx or ev.x, ev.ly or ev.y, ev.status)
			if result ~= iup.IGNORE then
				return split.event(owner, Element.state(owner), ev, rt)
			end
			return true
		end
	end
	if ev.type == "enter" then st.data.hot = true; if rt.redraw then rt.redraw(e) end; return true end
	if ev.type == "leave" then st.data.hot = false; if rt.redraw then rt.redraw(e) end; return true end
	if ev.type == "move" then
		Element.call(e, "FLAT_MOTION_CB", ev.lx or ev.x, ev.ly or ev.y, ev.status)
		if style(e) == "SASH" and rt.cursor then rt.cursor(horiz(e) and "SIZENS" or "SIZEWE") end
		return true
	end
	if (ev.type == "press" or ev.type == "release") and style(e) == "SASH" then
		local p = ev.type == "press" and 1 or 0
		local r = Element.call(e, "FLAT_BUTTON_CB", ev.button, p, ev.lx or ev.x, ev.ly or ev.y, ev.status)
		if r ~= require("core.imgui.iup").IGNORE then
			if p == 1 and rt.capture then rt.capture(e) elseif p == 0 and rt.release then rt.release() end
		end
		return true
	end
	return false
end
Classes.define{
	name = "flatseparator", children = 0, natural = natural, event = event,
	defaults = { ORIENTATION = "VERTICAL", STYLE = "SUNKENLINE", BARSIZE = "5", COLOR = "160 160 160", CANFOCUS = "NO" },
	callbacks = { FLAT_BUTTON_CB = true, FLAT_MOTION_CB = true },
	get = {
		ORIENTATION = function(e) return horiz(e) and "HORIZONTAL" or "VERTICAL" end,
		STYLE = style,
		BARSIZE = function(e) return tostring(tonumber(Element.own(e, "BARSIZE")) or 5) end,
	},
	draw = function(e, st, dc, rt)
		local c = attr(e, "COLOR") or "160 160 160"
		local hot = st.data.hot and (attr(e, "HLCOLOR") or c) or c
		if style(e) == "EMPTY" then return end
		if style(e) == "SASH" then
			if horiz(e) then dc:fill(st.x, st.y + math.floor(st.h / 2) - (st.data.hot and 1 or 0), st.w, st.data.hot and 2 or 1, hot)
			else dc:fill(st.x + math.floor(st.w / 2) - (st.data.hot and 1 or 0), st.y, st.data.hot and 2 or 1, st.h, hot) end
		elseif style(e) == "FILL" then
			dc:fill(st.x + 1, st.y + 1, math.max(0, st.w - 2), math.max(0, st.h - 2), c)
			dc:rect(st.x, st.y, st.w, st.h, Color.shade(Color.parse(c), -40))
		elseif horiz(e) then
			dc:line(st.x, st.y + math.floor(st.h / 2), st.x + st.w - 1, st.y + math.floor(st.h / 2), c, style(e) == "DUALLINES" and 1 or 1)
			if style(e) == "DUALLINES" then dc:line(st.x, st.y + math.floor(st.h / 2) + 2, st.x + st.w - 1, st.y + math.floor(st.h / 2) + 2, c, 1) end
		else
			dc:line(st.x + math.floor(st.w / 2), st.y, st.x + math.floor(st.w / 2), st.y + st.h - 1, c, 1)
			if style(e) == "DUALLINES" then dc:line(st.x + math.floor(st.w / 2) + 2, st.y, st.x + math.floor(st.w / 2) + 2, st.y + st.h - 1, c, 1) end
		end
	end,
}
return Classes
