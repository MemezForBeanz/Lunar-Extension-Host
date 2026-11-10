-- Virtual ports of Lunar's flatrows, flatsegmented, flatgrid, flatseek and videohost.
-- @module core.imgui.widgets.raw
local Classes = require("core.imgui.Classes")
local Element = require("core.imgui.Element")
local Fonts = require("core.imgui.Fonts")
local Draw = require("core.imgui.Draw")
local iup = require("core.imgui.iup")
local FlatScrollbar = require("core.imgui.widgets.flatscrollbar")

local M = {}
local function attr(e, n) return Element.getAttribute(e, n) end
local function own(e, n) return Element.own(e, n) end
local function yes(v) return v == true or tostring(v or ""):upper() == "YES" end
local function num(v, d) return tonumber(v) or d or 0 end
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function callbacks(e)
	local d = Element.state(e).data
	d.callbacks = d.callbacks or {}
	return d.callbacks
end
local function call(e, name, ...)
	local f = callbacks(e)[name]
	if type(f) == "function" then return f(...) end
end
local function set_data(e, k, v) Element.state(e).data[k] = v end
local function data(e, k, d) local v = Element.state(e).data[k]; return v == nil and d or v end
local function inside(st, x, y) return x >= st.x and y >= st.y and x < st.x + st.w and y < st.y + st.h end
local function rel(st, ev) return ev.lx or ((ev.x or 0) - st.x), ev.ly or ((ev.y or 0) - st.y) end
local function text(e, dc, s, x, y, w, h, color, opts)
	if s and s ~= "" then dc:text(tostring(s), x, y, w, h, color, Fonts.forElement(e), opts or { ellipsis = true, clip = true }) end
end
local function parse_ranges(s)
	local out = {}
	for part in tostring(s or ""):gmatch("[^,]+") do
		local a, b = part:match("^%s*([%+%-]?[%d%.]+)%s*%-%s*([%+%-]?[%d%.]+)%s*$")
		if a then out[#out + 1] = { tonumber(a), tonumber(b) }
		else
			a = part:match("^%s*([%+%-]?[%d%.]+)%s*$")
			if a then out[#out + 1] = { tonumber(a) } end
		end
	end
	return out
end
local function bits_image(e, rt, pixels, w, h, stride)
	if not pixels or not w or not h then return end
	local d = Element.state(e).data
	local B = rt and (rt.backend or rt.B)
	if not B or not B.texture then return end
	local key = tostring(pixels) .. ":" .. w .. ":" .. h .. ":" .. tostring(stride or 0)
	local cache = d.texture_cache or {}
	d.texture_cache = cache
	local item = cache[key]
	if not item then
		item = { tex = B.texture(pixels, w, h), w = w, h = h }
		cache[key] = item
	end
	return item
end
local function draw_bits(dc, item, x, y, w, h)
	if not item then return end
	dc:_emit("image", item.tex, x + dc.ox, y + dc.oy, x + dc.ox + (w or item.w),
		y + dc.oy + (h or item.h), 0, 0, 1, 1, 0xFFFFFFFF)
end

local function rows_height(e) return clamp(num(attr(e, "ROWHEIGHT"), 32), 20, 400) end
local function rows_header(e) return yes(attr(e, "HEADER")) and num(attr(e, "HEADERHEIGHT"), 26) or 0 end
local function rows_count(e) return num(attr(e, "COUNT"), 0) end
local function row_value(e, pos, field)
	local v = Element.getId(e, field, pos)
	return v ~= nil and v or call(e, "value", pos, field)
end
local function rows_natural(e)
	return 240, rows_header(e) + rows_height(e) * 5
end
local function rows_draw(e, st, dc, rt)
	FlatScrollbar.sync(e)
	local rh, header, count = rows_height(e), rows_header(e), rows_count(e)
	local bg, fg = attr(e, "BGCOLOR"), attr(e, "FGCOLOR")
	dc:fill(st.x, st.y, st.w, st.h, bg)
	if count == 0 then
		text(e, dc, attr(e, "EMPTYTITLE"), st.x + 16, st.y + st.h / 2 - 24, st.w - 32, 24, fg, { align = "center", ellipsis = true })
		text(e, dc, attr(e, "EMPTYHINT"), st.x + 16, st.y + st.h / 2 + 4, st.w - 32, 22, attr(e, "SECONDARYCOLOR") or fg, { align = "center", ellipsis = true })
		return
	end
	if header > 0 then
		dc:fill(st.x, st.y, st.w, header, attr(e, "HEADERCOLOR") or bg)
		text(e, dc, attr(e, "HEADERTITLE"), st.x + 12, st.y, st.w - 24, header, fg, { valign = "center", ellipsis = true })
		local x = st.x + st.w
		for i = 6, 1, -1 do
			local w = num(attr(e, "COLUMN" .. i .. "WIDTH"))
			if w > 0 then
				x = x - w
				text(e, dc, attr(e, "HEADER" .. i), x + 4, st.y, w - 8, header, attr(e, "SECONDARYCOLOR") or fg,
					{ align = tostring(attr(e, "COLUMN" .. i .. "ALIGN") or "RIGHT"):lower(), valign = "center", ellipsis = true })
			end
		end
	end
	local scroll = num(attr(e, "POSY"), 0)
	local first = math.max(1, math.floor(scroll / rh) + 1)
	local last = math.min(count, math.floor((scroll + st.h - header - 1) / rh) + 1)
	local iw, ih = 16, 16
	local isize = tostring(attr(e, "IMAGESIZE") or "")
	local a, b = isize:match("^(%d+)[xX](%d+)$")
	if a then iw, ih = tonumber(a), tonumber(b) elseif tonumber(isize) then iw, ih = tonumber(isize), tonumber(isize) end
	for pos = first, last do
		local y = st.y + header + (pos - 1) * rh - scroll
		local selected, hovered = tostring(attr(e, "VALUE") or "0") == tostring(pos), data(e, "hover") == pos
		if selected then dc:fill(st.x + 4, y + 1, st.w - 9, rh - 2, attr(e, "PSCOLOR") or bg, { radius = num(attr(e, "ITEMRADIUS"), 0) }) end
		if hovered and not selected then dc:fill(st.x + 4, y + 1, st.w - 9, rh - 2, attr(e, "HLCOLOR") or bg) end
		local x, right = st.x + 12, st.x + st.w - 12
		local image = row_value(e, pos, "IMAGE")
		if image then
			local img = Draw.resolveImage(image)
			if img then dc:image(img, x, y + (rh - ih) / 2, iw, ih) end
			x = x + iw + 8
		end
		for col = 6, 1, -1 do
			local w = num(attr(e, "COLUMN" .. col .. "WIDTH"))
			if w > 0 then right = right - w; text(e, dc, row_value(e, pos, "COLUMN" .. col), right + 4, y, w - 8, rh,
				attr(e, "SECONDARYCOLOR") or fg, { align = tostring(attr(e, "COLUMN" .. col .. "ALIGN") or "RIGHT"):lower(), valign = "center", ellipsis = true }) end
		end
		local action = row_value(e, pos, "ACTIONTEXT")
		if action and hovered then right = right - 58; text(e, dc, action, right, y, 54, rh, fg, { align = "right", valign = "center", ellipsis = true }) end
		local title = row_value(e, pos, "TITLE")
		text(e, dc, title, x, y + (rh == 44 and 2 or 0), math.max(0, right - x), rh == 44 and 21 or rh,
			selected and (attr(e, "TEXTPSCOLOR") or fg) or fg, { valign = rh == 44 and "top" or "center", ellipsis = true, clip = true })
		if rh >= 44 then text(e, dc, row_value(e, pos, "SECONDARY"), x, y + 23, math.max(0, right - x), 18,
			attr(e, "SECONDARYCOLOR") or fg, { ellipsis = true, clip = true }) end
		local progress = num(row_value(e, pos, "PROGRESS"), 0)
		if progress > 0 then dc:fill(x, y + rh - 3, (right - x) * clamp(progress, 0, 100) / 100, 2, attr(e, "ITEMMARKERCOLOR") or fg) end
		if data(e, "focus") and selected and yes(attr(e, "FOCUSFEEDBACK")) then dc:rect(st.x + 4, y + 1, st.w - 9, rh - 2, fg) end
	end
end
local function rows_select(e, st, pos, rt)
	pos = clamp(pos, 0, rows_count(e))
	if pos == num(attr(e, "VALUE"), 0) then return end
	Element.setAttribute(e, "VALUE", tostring(pos))
	call(e, "action", pos); Element.call(e, "VALUECHANGED_CB")
	if rt and rt.redraw then rt.redraw(e) end
end
local function rows_event(e, st, ev, rt)
	local x, y = rel(st, ev)
	if ev.type == "enter" then set_data(e, "hover", math.floor((y - rows_header(e) + num(attr(e, "POSY"))) / rows_height(e)) + 1); return true end
	if ev.type == "leave" then set_data(e, "hover", 0); return true end
	if ev.type == "move" then
		set_data(e, "hover", y >= rows_header(e) and math.floor((y - rows_header(e) + num(attr(e, "POSY"))) / rows_height(e)) + 1 or 0)
		call(e, "part", data(e, "hover"), "row"); return true
	end
	if ev.type == "wheel" then
		return FlatScrollbar.on_wheel(e, ev.dy or 0)
	end
	if ev.type == "press" and ev.button == 1 then
		local p = y >= rows_header(e) and math.floor((y - rows_header(e) + num(attr(e, "POSY"))) / rows_height(e)) + 1 or 0
		if p >= 1 and p <= rows_count(e) then
			rows_select(e, st, p, rt)
			call(e, "part", p, "row")
			if ev.status and iup.isdouble(ev.status) then call(e, "activate", p, "double") end
		end
		if rt and rt.capture then rt.capture(e) end
		return true
	elseif ev.type == "press" and ev.button == 3 then
		local p = math.floor((y - rows_header(e) + num(attr(e, "POSY"))) / rows_height(e)) + 1
		if p >= 1 and p <= rows_count(e) then call(e, "context", p, "context") end
		return true
	elseif ev.type == "key" then
		local base = iup.XkeyBase(ev.key or 0); local p = num(attr(e, "VALUE"), 0)
		if base == iup.K_UP then rows_select(e, st, p > 1 and p - 1 or 1, rt)
		elseif base == iup.K_DOWN then rows_select(e, st, p + 1, rt)
		elseif base == iup.K_HOME then rows_select(e, st, 1, rt)
		elseif base == iup.K_END then rows_select(e, st, rows_count(e), rt)
		elseif base == iup.K_PGUP then rows_select(e, st, p - math.max(1, math.floor((st.h - rows_header(e)) / rows_height(e))), rt)
		elseif base == iup.K_PGDN then rows_select(e, st, p + math.max(1, math.floor((st.h - rows_header(e)) / rows_height(e))), rt)
		elseif base == iup.K_CR or base == iup.K_KP_Enter then call(e, "activate", p, "enter")
		else return false end
		return true
	end
	return false
end

local function segment_natural(e)
	local count = clamp(num(attr(e, "COUNT"), 2), 2, 5)
	local f = Fonts.forElement(e); local maxw = 0
	for i = 0, count - 1 do maxw = math.max(maxw, f:measure(attr(e, "TITLE" .. i) or "") + 16) end
	return maxw * count, math.max(32, f:charsize())
end
local function segment_draw(e, st, dc)
	local count = clamp(num(attr(e, "COUNT"), 2), 2, 5); local value = num(attr(e, "VALUEPOS"), 0)
	local bg, fg = attr(e, "BGCOLOR"), attr(e, "FGCOLOR")
	dc:fill(st.x, st.y, st.w, st.h, bg, { radius = num(attr(e, "CORNERRADIUS"), 7) })
	for i = 0, count - 1 do
		local x, w = st.x + i * st.w / count, st.w / count
		if i == value then dc:fill(x + 2, st.y + 2, w - 4, st.h - 4, attr(e, "PSCOLOR") or bg, { radius = math.max(0, num(attr(e, "CORNERRADIUS"), 7) - 2) }) end
		text(e, dc, attr(e, "TITLE" .. i), x + 3, st.y, w - 6, st.h, i == value and (attr(e, "TEXTPSCOLOR") or fg) or fg, { align = "center", valign = "center", ellipsis = true })
	end
	dc:rect(st.x, st.y, st.w, st.h, attr(e, "BORDERCOLOR") or fg, { radius = num(attr(e, "CORNERRADIUS"), 7) })
end
local function segment_event(e, st, ev, rt)
	if ev.type == "press" and ev.button == 1 then
		local x = (ev.lx or ev.x - st.x); local p = clamp(math.floor(x / st.w * num(attr(e, "COUNT"), 2)), 0, num(attr(e, "COUNT"), 2) - 1)
		if tostring(attr(e, "VALUEPOS")) ~= tostring(p) then Element.setAttribute(e, "VALUEPOS", tostring(p)); call(e, "changed", p); Element.call(e, "VALUECHANGED_CB"); if rt and rt.redraw then rt.redraw(e) end end
		if rt and rt.setFocus then rt.setFocus(e) end
		return true
	elseif ev.type == "key" then
		local base = iup.XkeyBase(ev.key or 0); local p = num(attr(e, "VALUEPOS"), 0)
		if base == iup.K_LEFT or base == iup.K_UP then p = p - 1 elseif base == iup.K_RIGHT or base == iup.K_DOWN then p = p + 1 elseif base == iup.K_HOME then p = 0 elseif base == iup.K_END then p = num(attr(e, "COUNT"), 2) - 1 else return false end
		p = clamp(p, 0, num(attr(e, "COUNT"), 2) - 1); Element.setAttribute(e, "VALUEPOS", tostring(p)); call(e, "changed", p); return true
	end
	return false
end

local function grid_geometry(e, st)
	local w, gutter, padding = num(attr(e, "CELLWIDTH"), 150), math.max(num(attr(e, "GUTTER"), 16), 0), math.max(num(attr(e, "PADDING"), 16), 0)
	local aspect = tostring(attr(e, "ASPECT") or "2:3"); local a, b = aspect:match("^(%d+%.?%d*):(%d+%.?%d*)"); local ratio = a and tonumber(a) / tonumber(b) or tonumber(aspect) or 2 / 3
	local ih = math.max(16, math.floor(w / ratio + .5)); local show = tostring(attr(e, "SHOWTEXT") or "YES"):upper() ~= "NO"
	local lh = Fonts.forElement(e):charsize(); local ch = ih + (show and lh * 2 + 10 or 0)
	local lanes = tostring(attr(e, "ORIENTATION") or "VERTICAL"):upper() == "HORIZONTAL" and math.max(1, num(attr(e, "ROWS"), 1)) or math.max(1, math.floor((st.w - 2 * padding + gutter) / (w + gutter)))
	return w, ih, ch, gutter, padding, lanes
end
local function grid_pos(e, st, pos)
	local w, ih, ch, gutter, padding, lanes = grid_geometry(e, st); local line, lane = math.floor((pos - 1) / lanes), (pos - 1) % lanes
	local horizontal = tostring(attr(e, "ORIENTATION") or "VERTICAL"):upper() == "HORIZONTAL"; local scroll = num(attr(e, horizontal and "POSX" or "POSY"))
	if horizontal then return padding + line * (w + gutter) - scroll, padding + lane * (ch + gutter), w, ih, ch end
	return padding + (lanes > 1 and lane * (st.w - 2 * padding - w) / (lanes - 1) or 0), padding + line * (ch + gutter) - scroll, w, ih, ch
end
local function grid_natural(e, st) local w, ih, ch, gutter, padding = grid_geometry(e, st); return 2 * w + gutter + 2 * padding, ch + 2 * padding end
local function grid_draw(e, st, dc, rt)
	FlatScrollbar.sync(e)
	dc:fill(st.x, st.y, st.w, st.h, attr(e, "BGCOLOR")); local count = num(attr(e, "COUNT")); local _, _, _, _, padding, lanes = grid_geometry(e, st)
	local horizontal = tostring(attr(e, "ORIENTATION") or "VERTICAL"):upper() == "HORIZONTAL"; local scroll = num(attr(e, horizontal and "POSX" or "POSY")); local _, ih, ch, gutter = grid_geometry(e, st)
	local first = math.max(1, math.floor(math.max(0, scroll - padding) / (horizontal and (num(attr(e, "CELLWIDTH"), 150) + gutter) or (ch + gutter)) * lanes) + 1)
	local last = math.min(count, first + math.ceil((horizontal and st.w or st.h) / (horizontal and num(attr(e, "CELLWIDTH"), 150) + gutter or ch + gutter) + 1) * lanes)
	for pos = first, last do
		local x, y, w, iw, cellh = grid_pos(e, st, pos); local selected = tostring(attr(e, "VALUE") or "0") == tostring(pos); local marked = selected
		local mask = attr(e, "SELECTIONMASK"); if mask and mask:sub(pos, pos) == "+" then marked = true end
		local title, state = call(e, "value", pos, "TITLE"), call(e, "value", pos, "STATE")
		local hovered = data(e, "hover") == pos
		local bits, stride = call(e, "bits", pos, iw, ih)
		local image = bits_image(e, rt, bits, iw, ih, stride)
		if image then draw_bits(dc, image, st.x + x, st.y + y, iw, ih) else dc:fill(st.x + x, st.y + y, iw, ih, attr(e, "PLACEHOLDERCOLOR") or attr(e, "HLCOLOR") or attr(e, "BGCOLOR"), { radius = num(attr(e, "ITEMRADIUS"), 6) }) end
		local progress = num(call(e, "value", pos, "PROGRESS")); if progress > 0 then dc:fill(st.x + x + 6, st.y + y + ih - 10, (iw - 12) * clamp(progress, 0, 100) / 100, 3, attr(e, "ITEMMARKERCOLOR") or attr(e, "FGCOLOR")) end
		if state == "unplayed" then dc:circle(st.x + x + 9, st.y + y + 9, 3, attr(e, "ITEMMARKERCOLOR") or attr(e, "FGCOLOR"), { filled = true }) end
		if marked then dc:rect(st.x + x - 2, st.y + y - 2, iw + 4, ih + 4, attr(e, "ITEMMARKERCOLOR") or attr(e, "FGCOLOR"), { radius = num(attr(e, "ITEMRADIUS"), 6) + 2 }) elseif hovered then dc:rect(st.x + x - 1, st.y + y - 1, iw + 2, ih + 2, attr(e, "HLCOLOR") or attr(e, "FGCOLOR"), { radius = num(attr(e, "ITEMRADIUS"), 6) + 1 }) end
		if tostring(attr(e, "SHOWTEXT") or "YES"):upper() ~= "NO" then
			text(e, dc, title, st.x + x, st.y + y + ih + 6, iw, cellh - ih, attr(e, "FGCOLOR"), { ellipsis = true, clip = true })
			text(e, dc, call(e, "value", pos, "SECONDARY"), st.x + x, st.y + y + ih + 6 + Fonts.forElement(e):charsize(), iw, cellh - ih, attr(e, "SECONDARYCOLOR") or attr(e, "FGCOLOR"), { ellipsis = true, clip = true })
		end
	end
end
local function grid_hit(e, st, x, y)
	local count = num(attr(e, "COUNT")); for pos = 1, count do local px, py, w, ih, ch = grid_pos(e, st, pos); if x >= px and x < px + w and y >= py and y < py + ch then return pos end end
	return 0
end
local function grid_go(e, st, pos, rt, mode)
	local count = num(attr(e, "COUNT")); if count == 0 then return end; pos = clamp(pos, 1, count)
	if yes(attr(e, "MULTIPLE")) then
		local mask = attr(e, "SELECTIONMASK") or string.rep("-", count); local chars = {}; for i = 1, count do chars[i] = mask:sub(i, i) == "+" and "+" or "-" end
		if mode == "toggle" then chars[pos] = chars[pos] == "+" and "-" or "+" elseif mode == "extend" then local old = num(attr(e, "VALUE")); local a, b = math.min(old > 0 and old or pos, pos), math.max(old > 0 and old or pos, pos); for i = a, b do chars[i] = "+" end else for i = 1, count do chars[i] = "-" end; chars[pos] = "+" end
		Element.setAttribute(e, "SELECTIONMASK", table.concat(chars))
	end
	Element.setAttribute(e, "VALUE", tostring(pos)); call(e, "action", pos); call(e, "changed"); if rt and rt.redraw then rt.redraw(e) end
end
local function grid_event(e, st, ev, rt)
	local x, y = rel(st, ev)
	if ev.type == "move" or ev.type == "enter" then set_data(e, "hover", grid_hit(e, st, x, y)); return true end
	if ev.type == "leave" then set_data(e, "hover", 0); return true end
	if ev.type == "wheel" then local horizontal = tostring(attr(e, "ORIENTATION") or "VERTICAL"):upper() == "HORIZONTAL"; Element.setAttribute(e, horizontal and "POSX" or "POSY", tostring(math.max(0, num(attr(e, horizontal and "POSX" or "POSY")) - (ev.dy or 0) * 32))); return true end
	if ev.type == "press" then
		local pos = grid_hit(e, st, x, y); if not pos then return true end
		if ev.button == 3 then call(e, "context", pos, "context") elseif ev.button == 1 then grid_go(e, st, pos, rt, ev.status and iup.iscontrol(ev.status) and "toggle" or ev.status and iup.isshift(ev.status) and "extend" or "plain"); if ev.status and iup.isdouble(ev.status) then call(e, "activate", pos, "double") end end
		if rt and rt.setFocus then rt.setFocus(e) end; return true
	elseif ev.type == "key" then
		local base, pos = iup.XkeyBase(ev.key or 0), num(attr(e, "VALUE"), 0); local _, _, _, _, _, lanes = grid_geometry(e, st); local step = base == iup.K_LEFT and -1 or base == iup.K_RIGHT and 1 or base == iup.K_UP and -lanes or base == iup.K_DOWN and lanes or 0
		if base == iup.K_HOME then grid_go(e, st, 1, rt, "plain") elseif base == iup.K_END then grid_go(e, st, num(attr(e, "COUNT")), rt, "plain") elseif step ~= 0 then grid_go(e, st, pos + step, rt, "plain") elseif base == iup.K_CR then call(e, "activate", pos, "enter") elseif base == iup.K_SP and yes(attr(e, "MULTIPLE")) then grid_go(e, st, pos, rt, "toggle") else return false end
		return true
	end
	return false
end

local function seek_natural() return 240, 24 end
local function seek_position(e, st, x)
	local left, right = 8, math.max(8, st.w - 8); return clamp((x - left) / math.max(1, right - left), 0, 1) * num(attr(e, "MAX"))
end
local function seek_draw(e, st, dc)
	local maxv, value = num(attr(e, "MAX")), num(attr(e, "VALUE")); local left, right = st.x + 8, st.x + st.w - 8; local y = st.y + st.h / 2
	dc:line(left, y, right, y, attr(e, "BGCOLOR") or attr(e, "FGCOLOR"), num(attr(e, "LINEWIDTH"), 4))
	for _, r in ipairs(parse_ranges(attr(e, "BUFFERED"))) do if r[2] then dc:line(left + (right-left) * r[1] / math.max(1,maxv), y, left + (right-left) * r[2] / math.max(1,maxv), y, attr(e, "BUFFEREDCOLOR") or attr(e, "SECONDARYCOLOR") or attr(e, "FGCOLOR"), num(attr(e, "BUFFEREDWIDTH"), 5)) end end
	for _, r in ipairs(parse_ranges(attr(e, "MARKS"))) do local x = left + (right-left) * r[1] / math.max(1,maxv); if r[2] then dc:line(x, y - 3, left + (right-left) * r[2] / math.max(1,maxv), y - 3, attr(e, "MARKCOLOR") or attr(e, "FGCOLOR"), 2) else dc:line(x, y - 5, x, y + 5, attr(e, "MARKCOLOR") or attr(e, "FGCOLOR"), 1) end end
	dc:line(left, y, left + (right-left) * value / math.max(1,maxv), y, attr(e, "PSCOLOR") or attr(e, "FGCOLOR"), num(attr(e, "LINEWIDTH"), 4))
	dc:circle(left + (right-left) * value / math.max(1,maxv), y, num(attr(e, "THUMB"), 6), attr(e, "THUMBCOLOR") or attr(e, "FGCOLOR"), { filled = true })
end
local function seek_event(e, st, ev, rt)
	if ev.type == "move" or ev.type == "enter" then
		local x = rel(st, ev); local v = seek_position(e, st, x)
		set_data(e, "hover", v); call(e, "hover", v, x)
		if data(e, "drag") then Element.state(e).attrs.VALUE = tostring(v); call(e, "changing", v) end
		return true
	end
	if ev.type == "leave" then set_data(e, "hover", nil); call(e, "hover", num(attr(e, "VALUE")), -1); return true end
	if ev.type == "press" and ev.button == 1 then
		set_data(e, "drag", true); local v = seek_position(e, st, rel(st, ev))
		Element.state(e).attrs.VALUE = tostring(v); call(e, "changing", v)
		if rt and rt.capture then rt.capture(e) end
		return true
	end
	if ev.type == "release" and ev.button == 1 and data(e, "drag") then
		set_data(e, "drag", false); local v = seek_position(e, st, rel(st, ev))
		Element.state(e).attrs.VALUE = tostring(v); call(e, "seek", v)
		if rt and rt.release then rt.release() end
		return true
	end
	if ev.type == "key" then local base = iup.XkeyBase(ev.key or 0); local v = num(attr(e, "VALUE")); local step = num(attr(e, "STEP"), 1); if base == iup.K_LEFT then v = v - step elseif base == iup.K_RIGHT then v = v + step elseif base == iup.K_HOME then v = 0 elseif base == iup.K_END then v = num(attr(e, "MAX")) elseif base == iup.K_PGUP then v = v - num(attr(e, "PAGESTEP"), step * 10) elseif base == iup.K_PGDN then v = v + num(attr(e, "PAGESTEP"), step * 10) else return false end; v = clamp(v, 0, num(attr(e, "MAX"))); Element.setAttribute(e, "VALUE", tostring(v)); call(e, "seek", v); return true end
	return false
end

local function video_draw(e, st, dc, rt)
	dc:fill(st.x, st.y, st.w, st.h, attr(e, "BGCOLOR") or "0 0 0")
	local B = rt and (rt.backend or rt.B); if B and B.window then Element.state(e).data.window_id = B.window("hwnd") end
	Element.state(e).data.rect = { x = st.x, y = st.y, w = st.w, h = st.h }
end

Classes.define{ name = "flatrows", children = 0, focusable = true, visibleChildren = FlatScrollbar.visible_children, defaults = { COUNT = "0", ROWHEIGHT = "32", FOCUSFEEDBACK = "YES", ITEMRADIUS = "6", ACTIVE = "YES", FLATSCROLLBAR = "YES", SCROLLBARSIZE = "12", BGCOLOR = "255 255 255", FGCOLOR = "30 30 30" }, callbacks = { VALUECHANGED_CB = true }, natural = rows_natural, draw = rows_draw, event = rows_event,
	create = function(e) FlatScrollbar.create(e) end,
	get = { HOVER = function(e) return tostring(data(e, "hover", 0)) end, ACCESSIBLEVALUE = function(e) local p = num(attr(e, "VALUE")); return p > 0 and row_value(e, p, "TITLE") end,
		POSY = function(e) return num(own(e, "POSY")) end, YMAX = function(e) return rows_count(e) * rows_height(e) + rows_header(e) end,
		DY = function(e, s) return s.h end, XMAX = function() return 0 end, DX = function(e, s) return s.w end },
	set = { VALUE = function(e, st, v) st.attrs.VALUE = tostring(v or 0); return false end } }
Classes.define{ name = "flatsegmented", children = 0, focusable = true, defaults = { COUNT = "2", VALUEPOS = "0", CORNERRADIUS = "7", FOCUSFEEDBACK = "YES", BGCOLOR = "235 235 235", FGCOLOR = "30 30 30", PSCOLOR = "255 255 255" }, callbacks = { VALUECHANGED_CB = true }, natural = segment_natural, draw = segment_draw, event = segment_event }
Classes.define{ name = "flatgrid", children = 0, focusable = true, visibleChildren = FlatScrollbar.visible_children, defaults = { COUNT = "0", CELLWIDTH = "150", ASPECT = "2:3", GUTTER = "16", PADDING = "16", ROWS = "1", ORIENTATION = "VERTICAL", SHOWTEXT = "YES", MULTIPLE = "NO", FLATSCROLLBAR = "YES", SCROLLBARSIZE = "12", ITEMRADIUS = "6", FOCUSFEEDBACK = "YES" }, natural = grid_natural, draw = grid_draw, event = grid_event,
	create = function(e) FlatScrollbar.create(e) end,
	get = {
		POSY = function(e) return num(own(e, "POSY")) end, POSX = function(e) return num(own(e, "POSX")) end,
		YMAX = function(e, s) local _, _, ch, gutter, padding, lanes = grid_geometry(e, s); return tostring(attr(e, "ORIENTATION") or "VERTICAL"):upper() == "HORIZONTAL" and 0 or 2 * padding + math.ceil(num(attr(e, "COUNT")) / lanes) * (ch + gutter) - gutter end,
		XMAX = function(e, s) local w, _, _, gutter, padding, lanes = grid_geometry(e, s); return tostring(attr(e, "ORIENTATION") or "VERTICAL"):upper() == "HORIZONTAL" and 2 * padding + math.ceil(num(attr(e, "COUNT")) / lanes) * (w + gutter) - gutter or 0 end,
		DY = function(e, s) return tostring(attr(e, "ORIENTATION") or "VERTICAL"):upper() == "HORIZONTAL" and 0 or s.h end,
		DX = function(e, s) return tostring(attr(e, "ORIENTATION") or "VERTICAL"):upper() == "HORIZONTAL" and s.w or s.w end,
	SELECTIONMASK = function(e) return own(e, "SELECTIONMASK") or string.rep("-", num(attr(e, "COUNT"))) end,
	VISIBLERANGE = function(e, st)
		local c = num(attr(e, "COUNT")); if c == 0 then return nil end
		local _, _, ch, gutter, padding, lanes = grid_geometry(e, st)
		local horizontal = tostring(attr(e, "ORIENTATION") or "VERTICAL"):upper() == "HORIZONTAL"
		local pitch = horizontal and (num(attr(e, "CELLWIDTH"), 150) + gutter) or (ch + gutter)
		local scroll = num(attr(e, horizontal and "POSX" or "POSY"))
		local first = math.floor(math.max(0, scroll - padding) / pitch) * lanes + 1
		local last = math.min(c, (math.floor((scroll + (horizontal and st.w or st.h)) / pitch) + 1) * lanes)
		return tostring(first) .. ":" .. tostring(last)
	end
} }
Classes.define{ name = "flatseek", children = 0, focusable = true, defaults = { MAX = "0", VALUE = "0", STEP = "1", PAGESTEP = "10", LINEWIDTH = "4", FOCUSFEEDBACK = "YES" }, callbacks = { VALUECHANGED_CB = true }, natural = seek_natural, draw = seek_draw, event = seek_event,
	set = { VALUE = function(e, st, v) if st.data.drag then return false end end } }
Classes.define{ name = "videohost", children = 0, defaults = { BGCOLOR = "0 0 0" }, natural = function() return 320, 180 end, draw = video_draw, get = { WINDOWID = function(e) local v = data(e, "window_id"); return v and tostring(v) end }, methods = { windowId = function(e) local v = data(e, "window_id"); return v and tostring(v) end, rect = function(e) return data(e, "rect") end } }

function M.bind(e, kind, cb) callbacks(e)[kind] = cb end
return M
