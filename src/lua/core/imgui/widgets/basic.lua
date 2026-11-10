-- Classic IUP controls used by Lunar. They are intentionally owner drawn so the
-- controls retain the dimensions and colours of the Windows themed UI.
-- @module core.imgui.widgets.basic
local Classes = require("core.imgui.Classes")
local Element = require("core.imgui.Element")
local Fonts = require("core.imgui.Fonts")
local Draw = require("core.imgui.Draw")
local iup = require("core.imgui.iup")

local function attr(e, n) return Element.getAttribute(e, n) end
local yes = Element.isTrue -- iupStrBoolean
local function pad(e)
	local a, b = tostring(attr(e, "PADDING") or "0x0"):match("^%s*(-?[%d%.]*)x(-?[%d%.]*)")
	return tonumber(a) or 0, tonumber(b) or 0
end
local function image(e, n) return Draw.resolveImage(attr(e, n)) end
local function align(v, fallback)
	local a, b = tostring(v or fallback):match("^([^:]+):?(.*)$")
	return (a or fallback):upper(), b ~= "" and b:upper() or "ATOP"
end
local function text_size(e, L)
	local title = attr(e, "TITLE") or ""
	local f = L.font(e)
	local w, h = f:measure(title)
	local im = image(e, "IMAGE")
	if im then
		local iw, ih = Draw.imageSize(im)
		if title ~= "" then w = w + iw + 2; h = math.max(h, ih) else w, h = iw, ih end
	end
	local x, y = pad(e)
	return w + x * 2, h + y * 2
end
local function natural_text(e, st, L)
	local w, h = text_size(e, L)
	local rw, rh = L.size(Element.own(e, "RASTERSIZE"))
	return rw or w, rh or h
end
local function background(e, st, dc, pressed)
	local bg = attr(e, "BGCOLOR")
	if pressed then bg = attr(e, "PSCOLOR") or bg elseif st.highlighted then bg = attr(e, "HLCOLOR") or bg end
	if bg then dc:fill(st.x, st.y, st.w, st.h, bg, { radius = tonumber(attr(e, "CORNERRADIUS")) or 0 }) end
	local bw = tonumber(attr(e, "BORDERWIDTH")) or 1
	if yes(attr(e, "SHOWBORDER")) or st.highlighted or pressed then
		dc:rect(st.x, st.y, st.w, st.h, attr(e, "BORDERCOLOR") or attr(e, "FGCOLOR"), { radius = tonumber(attr(e, "CORNERRADIUS")) or 0, thickness = bw })
	end
	return attr(e, "FGCOLOR"), bw
end
local function draw_text_image(e, st, dc, fg, x, y, w, h)
	local title, im = attr(e, "TITLE") or "", image(e, "IMAGE")
	local px, py = pad(e)
	x, y, w, h = x + px, y + py, w - px * 2, h - py * 2
	if im then
		local iw, ih = Draw.imageSize(im)
		dc:image(im, x, y + math.floor((h - ih) / 2), iw, ih, { inactive = attr(e, "ACTIVE") == "NO" })
		if title ~= "" then x, w = x + iw + 2, w - iw - 2 end
	end
	if title ~= "" then
		local ha, va = align(attr(e, "ALIGNMENT"), "ACENTER:ACENTER")
		dc:text(title, x, y, w, h, fg, Fonts.forElement(e), { align = ha, valign = va, wrap = yes(attr(e, "WORDWRAP")), ellipsis = yes(attr(e, "ELLIPSIS")), clip = true })
	end
end
local function basic_event(e, st, ev, rt, activate)
	if ev.type == "enter" then st.highlighted = true; rt.redraw(e); return true end
	if ev.type == "leave" then st.highlighted = false; rt.redraw(e); return true end
	if ev.type == "focus" then st.focused = true; rt.redraw(e); return true end
	if ev.type == "blur" then st.focused = false; rt.redraw(e); return true end
	if ev.type == "press" and ev.button == 1 then st.pressed = true; rt.capture(e); rt.setFocus(e); rt.redraw(e); return true end
	if ev.type == "release" and ev.button == 1 then
		local inside = ev.lx >= 0 and ev.ly >= 0 and ev.lx < st.w and ev.ly < st.h
		st.pressed = false; rt.release()
		if inside then local r = activate(e, st); if r == iup.CLOSE then ev.result = r end end
		rt.redraw(e); return true
	end
	if ev.type == "key" and st.focused and (ev.key == iup.K_SP or ev.key == iup.K_CR) then
		local r = activate(e, st); if r == iup.CLOSE then ev.result = r end; rt.redraw(e); return true
	end
	return false
end

local function label_natural(e, st, L)
	local w, h = natural_text(e, st, L)
	local sep = tostring(attr(e, "SEPARATOR") or ""):upper()
	if sep == "HORIZONTAL" then return 0, tonumber(attr(e, "RASTERSIZE") or "") or 1 end
	if sep == "VERTICAL" then return 1, 0 end
	return w, h
end
local function label_draw(e, st, dc)
	local sep = tostring(attr(e, "SEPARATOR") or ""):upper()
	if sep == "HORIZONTAL" then dc:fill(st.x, st.y + math.floor(st.h / 2), st.w, 1, attr(e, "FGCOLOR")); return end
	if sep == "VERTICAL" then dc:fill(st.x + math.floor(st.w / 2), st.y, 1, st.h, attr(e, "FGCOLOR")); return end
	if attr(e, "ACTIVE") == "NO" then return end
	draw_text_image(e, st, dc, attr(e, "FGCOLOR"), st.x, st.y, st.w, st.h)
end

local function button_draw(e, st, dc)
	local fg = background(e, st, dc, st.pressed and st.highlighted)
	draw_text_image(e, st, dc, st.pressed and (attr(e, "TEXTPSCOLOR") or fg) or fg, st.x, st.y, st.w, st.h)
	if st.focused and attr(e, "FOCUSFEEDBACK") ~= "NO" then dc:rect(st.x + 1, st.y + 1, st.w - 2, st.h - 2, fg, { thickness = 1 }) end
end
local function button_activate(e)
	local r = Element.call(e, "BUTTON_CB", 1, 0, 0, 0, iup._status())
	if r == iup.IGNORE then return r end
	return Element.call(e, "ACTION")
end
local function toggle_activate(e, st)
	local v = tostring(st.value or attr(e, "VALUE") or "OFF"):upper() == "ON" and "OFF" or "ON"
	st.value = v
	local r = Element.call(e, "ACTION", v)
	if r == iup.CLOSE then return r end
	return Element.call(e, "VALUECHANGED_CB")
end

local function progress_natural(e, st, L)
	local cw, ch = L.charsize(e)
	local rw, rh = L.size(Element.own(e, "RASTERSIZE"))
	return rw or cw * 10, rh or ch
end
local function progress_draw(e, st, dc, rt)
	local bg, fg = attr(e, "BGCOLOR"), attr(e, "FGCOLOR")
	local radius = tonumber(attr(e, "CORNERRADIUS")) or 0
	dc:fill(st.x, st.y, st.w, st.h, bg, { radius = radius })
	local min, max = tonumber(attr(e, "MIN")) or 0, tonumber(attr(e, "MAX")) or 1
	local val = tonumber(attr(e, "VALUE")) or min
	local ratio = max > min and math.max(0, math.min(1, (val - min) / (max - min))) or 0
	if yes(attr(e, "MARQUEE")) then
		rt.animate(e)
		local phase = (rt.now and rt.now() or 0) % 1
		ratio = 0.25
		local x = st.x + (st.w - st.w * ratio) * phase
		dc:fill(x, st.y, st.w * ratio, st.h, fg, { radius = radius })
	elseif tostring(attr(e, "ORIENTATION") or "HORIZONTAL"):upper() == "VERTICAL" then
		dc:fill(st.x, st.y + st.h * (1 - ratio), st.w, st.h * ratio, fg, { radius = radius })
	elseif yes(attr(e, "DASHED")) then
		local step, on = 6, 4
		local limit = st.w * ratio
		for x = 0, limit - 1, step do dc:fill(st.x + x, st.y, math.min(on, limit - x), st.h, fg, { radius = radius }) end
	else dc:fill(st.x, st.y, st.w * ratio, st.h, fg, { radius = radius }) end
	if attr(e, "BORDERCOLOR") then dc:rect(st.x, st.y, st.w, st.h, attr(e, "BORDERCOLOR"), { radius = radius, thickness = 1 }) end
end

-- iLabelSetSeparatorAttrib: a separator expands freely along its line
local function label_expand(e)
	local sep = tostring(attr(e, "SEPARATOR") or ""):upper()
	if sep == "HORIZONTAL" then return "HORIZONTALFREE" end
	if sep == "VERTICAL" then return "VERTICALFREE" end
	return nil
end
Classes.define{name="label", children=0, defaults={ACTIVE="YES"}, natural=label_natural, draw=label_draw,
	expandDefault=label_expand}
Classes.define{name="button", children=0, defaults={PADDING="4x2", CANFOCUS="YES", ACTIVE="YES"}, natural=natural_text, draw=button_draw, event=function(e,s,ev,rt) return basic_event(e,s,ev,rt,button_activate) end, focusable=true, callbacks={ACTION=true, BUTTON_CB=true}}
Classes.define{name="toggle", children=0, defaults={VALUE="OFF", CANFOCUS="YES", ACTIVE="YES"}, natural=natural_text, draw=button_draw, event=function(e,s,ev,rt) return basic_event(e,s,ev,rt,toggle_activate) end, focusable=true, callbacks={ACTION=true, VALUECHANGED_CB=true}, set={VALUE=function(e,s,v) s.value=tostring(v or "OFF"):upper() end}, get={VALUE=function(e,s) return s.value end}}
Classes.define{name="link", children=0, defaults={CANFOCUS="YES", ACTIVE="YES"}, natural=natural_text, draw=function(e,s,dc) draw_text_image(e,s,dc,attr(e,"FGCOLOR"),s.x,s.y,s.w,s.h) end, event=function(e,s,ev,rt) return basic_event(e,s,ev,rt,function(el) local url=attr(el,"URL"); local ok,d=pcall(require,"core.lib.desktop"); if ok and d and d.open then d.open(url) end; return Element.call(el,"ACTION",url) end) end, focusable=true, callbacks={ACTION=true}}
Classes.define{name="progressbar", children=0, defaults={MIN="0", MAX="1", VALUE="0", ORIENTATION="HORIZONTAL", ACTIVE="YES"}, natural=progress_natural, draw=progress_draw}

return Classes
