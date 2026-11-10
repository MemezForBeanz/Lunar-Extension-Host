-- Owner-drawn IUP canvas and its flat scrollbars.
-- @module core.imgui.widgets.canvas
local Classes = require("core.imgui.Classes")
local Element = require("core.imgui.Element")
local Draw = require("core.imgui.Draw")
local iup = require("core.imgui.iup")

local function attr(e, n) return Element.getAttribute(e, n) end
local yes = Element.isTrue -- iupStrBoolean
local function call_result(e, name, ...)
	return Element.call(e, name, ...)
end
local function natural(e, st, L)
	local cw, ch = L.charsize(e)
	local rw, rh = L.size(Element.own(e, "RASTERSIZE"))
	return rw or cw, rh or ch
end
local function draw(e, st, dc, rt)
	if attr(e, "BGCOLOR") then dc:fill(st.x, st.y, st.w, st.h, attr(e, "BGCOLOR")) end
	if not st.mapped then st.mapped = true; call_result(e, "MAP_CB") end
	if st.last_w ~= st.w or st.last_h ~= st.h then
		st.last_w, st.last_h = st.w, st.h
		call_result(e, "RESIZE_CB", st.w, st.h)
	end
	local function draw_after(e, st, dc)
		local sb = tostring(attr(e, "SCROLLBAR") or "NO"):upper()
		if sb == "NO" then return end
		local fg = attr(e, "SB_FORECOLOR") or attr(e, "FGCOLOR") or "128 128 128"
		local bg = attr(e, "SB_BACKCOLOR") or attr(e, "BGCOLOR")
		local size = tonumber(attr(e, "SCROLLBARSIZE")) or 10
		local radius = tonumber(attr(e, "SB_CORNERRADIUS")) or math.floor(size / 2)
		local function bar(horizontal)
			local max = tonumber(attr(e, horizontal and "XMAX" or "YMAX")) or 0
			local min = tonumber(attr(e, horizontal and "XMIN" or "YMIN")) or 0
			local pos = tonumber(attr(e, horizontal and "POSX" or "POSY")) or min
			local length = horizontal and st.w or st.h
			local range = math.max(1, max - min)
			local page = math.max(1, length * (horizontal and st.w or st.h) / (range + (horizontal and st.w or st.h)))
			page = math.min(length, page)
			local travel = math.max(0, length - page)
			local thumb = travel * math.max(0, math.min(1, (pos - min) / range))
			if horizontal then
				dc:fill(st.x, st.y + st.h - size, st.w, size, bg, { radius = radius })
				dc:fill(st.x + thumb, st.y + st.h - size, page, size, fg, { radius = radius })
			else
				dc:fill(st.x + st.w - size, st.y, size, st.h, bg, { radius = radius })
				dc:fill(st.x + st.w - size, st.y + thumb, size, page, fg, { radius = radius })
			end
		end
		if sb == "YES" or sb == "HORIZONTAL" then bar(true) end
		if sb == "YES" or sb == "VERTICAL" then bar(false) end
	end
	local dx, dy = tonumber(attr(e, "DX")) or 0, tonumber(attr(e, "DY")) or 0
	Draw.enterCanvas(e, dc)
	dc:offset_push(-dx, -dy)
	local result = call_result(e, "ACTION", tonumber(attr(e, "POSX")) or 0, tonumber(attr(e, "POSY")) or 0)
	dc:offset_pop()
	Draw.leaveCanvas()
	if result == iup.CLOSE then st.close_result = result end
	if attr(e, "BORDER") ~= "NO" then dc:rect(st.x, st.y, st.w, st.h, attr(e, "BORDERCOLOR") or attr(e, "FGCOLOR"), { thickness = 1 }) end
end
local function event(e, st, ev, rt)
	local x, y = ev.lx or ((ev.x or st.x) - st.x), ev.ly or ((ev.y or st.y) - st.y)
	local status = ev.status or iup._status(ev.mods)
	if ev.type == "press" or ev.type == "release" then
		-- IUP passes the button as the character '1' '2' '3' (iup.BUTTON1...)
		local r = call_result(e, "BUTTON_CB", ev.iupbutton or 48 + ev.button, ev.type == "press" and 1 or 0, x, y, status)
		if r == iup.CLOSE then ev.result = r end
		if ev.type == "press" then rt.capture(e) else rt.release() end
		return true
	elseif ev.type == "move" then
		local r = call_result(e, "MOTION_CB", x, y, status)
		if r == iup.CLOSE then ev.result = r end
		return true
	elseif ev.type == "wheel" then
		local r = call_result(e, "WHEEL_CB", ev.dy or ev.delta or 0, x, y, status)
		if r == iup.CLOSE then ev.result = r end
		return r ~= iup.IGNORE
	elseif ev.type == "enter" then return true -- the runtime fires ENTERWINDOW_CB for every element
	elseif ev.type == "leave" then return true
	elseif ev.type == "key" then
		local r = call_result(e, "KEYPRESS_CB", ev.key, 1)
		if r == iup.CLOSE then ev.result = r end
		return r ~= iup.IGNORE
	elseif ev.type == "char" then call_result(e, "KEYPRESS_CB", ev.char, 1); return true end
	return false
end
Classes.define{
	name="canvas", children=0, natural=natural, draw=draw, event=event,
	expandDefault="YES", -- iCanvasCreateMethod: ih->expand = IUP_EXPAND_BOTH
	drawAfter=draw_after,
	defaults={BORDER="YES", EXPAND="YES", CANFOCUS="YES", DRAWSTYLE="STROKE", DRAWLINEWIDTH="1"},
	callbacks={ACTION=true, BUTTON_CB=true, MOTION_CB=true, WHEEL_CB=true, ENTERWINDOW_CB=true, LEAVEWINDOW_CB=true, KEYPRESS_CB=true, K_ANY=true, RESIZE_CB=true, MAP_CB=true, SCROLL_CB=true},
	focusable=true,
}
return Classes
