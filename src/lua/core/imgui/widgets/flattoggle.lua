-- IUP flat toggle, including Lunar's rounded checkbox and Carbon switch.
-- @module core.imgui.widgets.flattoggle
local Classes = require("core.imgui.Classes")
local Element = require("core.imgui.Element")
local Fonts = require("core.imgui.Fonts")
local Draw = require("core.imgui.Draw")
local iup = require("core.imgui.iup")

local function attr(e, n) return Element.getAttribute(e, n) end
local function yes(v) return tostring(v or ""):upper() == "YES" end
local function number(e, n, d) return tonumber(attr(e, n)) or d end
local function pad(e)
	local x, y = tostring(attr(e, "PADDING") or "0x0"):match("^%s*(-?[%d%.]*)x(-?[%d%.]*)")
	return tonumber(x) or 0, tonumber(y) or 0
end
local function image(e, name)
	return Draw.resolveImage(attr(e, name))
end
local function active(e) return not (attr(e, "ACTIVE") == "NO") end
local function state_image(e, st, name)
	local suffix = not active(e) and "INACTIVE" or st.pressed and st.highlighted and "PRESS" or st.highlighted and "HIGHLIGHT" or nil
	return image(e, suffix and name .. suffix or name) or image(e, name)
end
local function image_size(e, name)
	local im = image(e, name)
	if not im then return 0, 0 end
	return Draw.imageSize(im)
end
local function alignment(v, fallback)
	v = tostring(v or fallback)
	local a, b = v:match("^([^:]+):?(.*)$")
	return a:upper(), b ~= "" and b:upper() or nil
end

local function content_size(e, L)
	local f = L.font(e)
	local title = attr(e, "TITLE") or ""
	local tw, th = f:measure(title)
	local iw, ih = image_size(e, "IMAGE")
	local spacing = number(e, "SPACING", 2)
	local p = tostring(attr(e, "IMAGEPOSITION") or "LEFT"):upper()
	local w, h = tw, th
	if iw > 0 then
		if p == "TOP" or p == "BOTTOM" then
			w, h = math.max(w, iw), ih + (title ~= "" and spacing or 0) + th
		else
			w, h = iw + (title ~= "" and spacing or 0) + tw, math.max(ih, th)
		end
	end
	local px, py = pad(e)
	local check = number(e, "CHECKSIZE", 0)
	if check > 0 then
		w = w + check + number(e, "CHECKSPACING", 2)
	end
	return w + px * 2, h + py * 2
end

local function set_value(e, st, value, notify)
	value = tostring(value or "OFF"):upper()
	if value ~= "ON" and value ~= "OFF" and value ~= "NOTDEF" then value = "OFF" end
	local old = tostring(st.value or attr(e, "VALUE") or "OFF"):upper()
	st.value = value
	st.attrs_value = value
	if notify and old ~= value then
		local r = Element.call(e, "FLAT_ACTION", value)
		if r == iup.CLOSE then return r end
		Element.call(e, "VALUECHANGED_CB")
	end
end

local function selected(e, st)
	local v = st.value or attr(e, "VALUE") or "OFF"
	return v == "ON" and 1 or v == "NOTDEF" and -1 or 0
end

local function notify(e, st)
	local v = selected(e, st)
	if yes(attr(e, "3STATE")) then
		v = v == 0 and -1 or v == -1 and 1 or 0
	else
		v = v == 0 and 1 or 0
	end
	return set_value(e, st, v == 1 and "ON" or v == -1 and "NOTDEF" or "OFF", true)
end

local function draw_switch(e, st, dc)
	local w, h = 36, 20
	local x, y = st.x + math.floor((st.w - w) / 2), st.y + math.floor((st.h - h) / 2)
	local pos = tonumber(attr(e, "SWITCHPOS"))
	if pos == nil then pos = selected(e, st) == 1 and 100 or 0 end
	pos = math.max(0, math.min(100, pos))
	local track = pos >= 50 and (attr(e, "SWITCHONCOLOR") or attr(e, "FGCOLOR")) or
		(attr(e, "SWITCHOFFCOLOR") or attr(e, "FGCOLOR"))
	local knob = attr(e, "SWITCHKNOBCOLOR") or attr(e, "BGCOLOR")
	local kx = x + 3 + math.floor(pos * (w - 20) / 100)
	dc:fill(x, y, w, h, track, { radius = h / 2 })
	dc:fill(kx, y + 3, 14, 14, knob, { radius = 7 })
end

local function draw(e, st, dc)
	local bg, fg = attr(e, "BGCOLOR"), attr(e, "FGCOLOR")
	local radius = number(e, "CORNERRADIUS", 0)
	local p = st.pressed and st.highlighted
	local sel = selected(e, st)
	if p or (sel ~= 0 and not st.highlighted) then bg, fg = attr(e, "PSCOLOR") or bg, attr(e, "TEXTPSCOLOR") or fg
	elseif st.highlighted then bg, fg = attr(e, "HLCOLOR") or bg, attr(e, "TEXTHLCOLOR") or fg end
	if not active(e) then st.inactive = true end
	if bg then
		local gc = attr(e, "GRADIENTCOLOR")
		if gc and not st.highlighted and not p then dc:gradient(st.x, st.y, st.w, st.h, bg, gc, attr(e, "GRADIENTDIRECTION") or "VERTICAL", { radius = radius })
		elseif image(e, "BACKIMAGE") then dc:image(image(e, "BACKIMAGE"), st.x, st.y, st.w, st.h, { inactive = not active(e) })
		else dc:fill(st.x, st.y, st.w, st.h, bg, { radius = radius }) end
	end
	local bw = number(e, "BORDERWIDTH", 1)
	if yes(attr(e, "SHOWBORDER")) or st.highlighted or p then
		dc:rect(st.x, st.y, st.w, st.h, attr(e, "BORDERPSCOLOR") or attr(e, "BORDERCOLOR") or fg, { radius = radius, thickness = bw })
	end
	if yes(attr(e, "SWITCH")) then draw_switch(e, st, dc); return end

	local check = number(e, "CHECKSIZE", 0)
	local left = st.x + bw
	if check > 0 then
		local right = attr(e, "CHECKALIGN") == "RIGHT"
		local cx = right and st.x + st.w - bw - check or left
		local cy = st.y + math.floor((st.h - check) / 2)
		local cpad = 2
		local ccolor = attr(e, "CHECKBGCOLOR") or bg
		local cstroke = attr(e, "CHECKFGCOLOR") or fg
		if st.highlighted then cstroke = attr(e, "CHECKHLCOLOR") or attr(e, "BORDERHLCOLOR") or cstroke end
		if p then cstroke = attr(e, "CHECKPSCOLOR") or cstroke end
		local size = check - cpad * 2
		if Element.state(st.parent) and Element.state(st.parent).classname == "radio" then
			dc:circle(cx + check / 2, cy + check / 2, math.max(1, size / 2), ccolor, { filled = true })
			dc:circle(cx + check / 2, cy + check / 2, math.max(1, size / 2), cstroke, { thickness = 1 })
			if sel ~= 0 then dc:circle(cx + check / 2, cy + check / 2, math.max(1, size / 2 - 4), cstroke, { filled = true }) end
		else
			dc:fill(cx + cpad, cy + cpad, size, size, ccolor, { radius = number(e, "CHECKRADIUS", 0) })
			dc:rect(cx + cpad, cy + cpad, size, size, cstroke, { radius = number(e, "CHECKRADIUS", 0), thickness = 1 })
			if sel == 1 then
				dc:line(cx + cpad + 3, cy + check / 2, cx + check / 2 - 1, cy + check - cpad - 3, cstroke, 2)
				dc:line(cx + check / 2 - 1, cy + check - cpad - 3, cx + check - cpad - 3, cy + cpad + 3, cstroke, 2)
			elseif sel == -1 then
				dc:fill(cx + cpad + 3, cy + check / 2 - 1, size - 6, 2, cstroke)
			end
		end
		left = right and st.x + bw or left + check + number(e, "CHECKSPACING", 2)
	end
	local title = attr(e, "TITLE") or ""
	local im = state_image(e, st, "IMAGE")
	local iw, ih = Draw.imageSize(im)
	local px, py = pad(e)
	local x, y, ww, hh = left + px, st.y + py, st.x + st.w - left - px - bw, st.h - py * 2
	if im then
		local pos = tostring(attr(e, "IMAGEPOSITION") or "LEFT"):upper()
		if pos == "RIGHT" then dc:image(im, x + ww - iw, y + math.floor((hh - ih) / 2), iw, ih, { inactive = not active(e) })
		elseif pos == "TOP" or pos == "BOTTOM" then
			local iy = pos == "TOP" and y or y + hh - ih
			dc:image(im, x + math.floor((ww - iw) / 2), iy, iw, ih, { inactive = not active(e) })
		else dc:image(im, x, y + math.floor((hh - ih) / 2), iw, ih, { inactive = not active(e) }); x = x + iw + number(e, "SPACING", 2); ww = ww - iw - number(e, "SPACING", 2) end
	end
	if title ~= "" then
		local ha, va = alignment(attr(e, "ALIGNMENT"), "ACENTER:ACENTER")
		dc:text(title, x, y, ww, hh, fg, Fonts.forElement(e), { align = ha, valign = va or "ACENTER", wrap = yes(attr(e, "WORDWRAP")), ellipsis = yes(attr(e, "ELLIPSIS")), clip = true })
	end
	if st.focused and attr(e, "FOCUSFEEDBACK") ~= "NO" then
		dc:rect(st.x + bw, st.y + bw, st.w - bw * 2, st.h - bw * 2, fg, { radius = math.max(1, radius - bw), thickness = 1 })
	end
end

local function event(e, st, ev, rt)
	if ev.type == "enter" then st.highlighted = true; rt.redraw(e); return true end
	if ev.type == "leave" then st.highlighted = false; rt.redraw(e); return true end
	if ev.type == "focus" then st.focused = true; rt.redraw(e); return true end
	if ev.type == "blur" then st.focused = false; rt.redraw(e); return true end
	if ev.type == "press" and ev.button == 1 then st.pressed = true; rt.capture(e); rt.setFocus(e); rt.redraw(e); return true end
	if ev.type == "release" and ev.button == 1 then
		local inside = ev.lx >= 0 and ev.ly >= 0 and ev.lx < st.w and ev.ly < st.h
		st.pressed = false; rt.release()
		if inside then local r = notify(e, st); if r == iup.CLOSE then ev.result = r end end
		rt.redraw(e); return true
	end
	if ev.type == "key" and st.focused and (ev.key == iup.K_SP or ev.key == iup.K_CR) then
		local r = notify(e, st); if r == iup.CLOSE then ev.result = r end; rt.redraw(e); return true
	end
	return false
end

local function natural(e, st, L)
	local w, h = content_size(e, L)
	local rw, rh = L.size(Element.own(e, "RASTERSIZE"))
	return rw or w, rh or h
end

Classes.define{
	name = "flattoggle", children = 0, focusable = function(e) return attr(e, "CANFOCUS") ~= "NO" end,
	defaults = { VALUE = "OFF", CHECKSIZE = "0", CHECKSPACING = "2", PADDING = "0x0", SPACING = "2", ALIGNMENT = "ACENTER:ACENTER", FOCUSFEEDBACK = "YES" },
	callbacks = { FLAT_ACTION = true, VALUECHANGED_CB = true },
	natural = natural, draw = draw, event = event,
	set = { VALUE = function(e, st, v) st.value = tostring(v or "OFF"):upper() end },
	get = { VALUE = function(e, st) return st.value end },
}

return Classes
