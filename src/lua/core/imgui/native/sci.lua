-- Scintilla message compatibility used by CodeView and LSP integrations.
-- Positions are byte offsets, as in Scintilla (SC_CP_UTF8).
local Element = require("core.imgui.Element")
local Scintilla = require("core.imgui.widgets.scintilla")

local Document = require("core.imgui.scintilla.document")
local View = require("core.imgui.scintilla.view")
local M = {}
local function st_of(el)
	local st = Element.state(el)
	if not st or st.classname ~= "scintilla" then error("sci: expected scintilla handle", 3) end
	return st
end
local function clamp(d, p) return math.max(0, math.min(#d.text, math.floor(tonumber(p) or 0))) end
local function line_start(s, line)
	if line < 0 then return -1 end
	local p = 1
	for _ = 1, line do
		p = s:find("\n", p, true)
		if not p then return #s end
		p = p + 1
	end
	return p - 1
end
local function line_end(s, line)
	local p = line_start(s, line)
	if p < 0 then return -1 end
	local n = s:find("\n", p + 1, true)
	return n and n - 1 or #s
end
local function line_count(s) return select(2, s:gsub("\n", "\n")) + 1 end
local function line_of(s, p) return select(2, s:sub(1, clamp({ text = s }, p)):gsub("\n", "\n")) end
local function char_width(el)
	local st = Element.state(el)
	local cw, ch = Scintilla._style_font(el, st, 32):charsize()
	return cw, ch + (st.data.extra_ascent or 0) + (st.data.extra_descent or 0)
end
local function utf8_size(b)
	if not b or b < 128 then return 1 end
	if b < 224 then return 2 end
	if b < 240 then return 3 end
	return 4
end
local function utf8_prev(s, p)
	p = math.max(0, p - 1)
	while p > 0 and (s:byte(p + 1) or 0) >= 128 and (s:byte(p + 1) or 0) < 192 do p = p - 1 end
	return p
end
local function utf8_next(s, p)
	local b = s:byte(p + 1)
	if not b then return #s end
	return math.min(#s, p + utf8_size(b))
end
local function visual_column(el, s, p, tab)
	local start = line_start(s, line_of(s, p))
	local col, i = 0, start + 1
	tab = tonumber(tab) or 4
	while i <= p do
		local b = s:byte(i)
		if b == 9 then col = col + (tab - col % tab) else col = col + 1 end
		i = i + utf8_size(b)
	end
	return col
end
local function edit(el, st, a, b, value) return View.edit(st, a, b, value) end
local function word_char(c) return c and c:match("[%w_]") ~= nil end
local function word_boundary(s, p, right)
	if right then
		while p < #s and not word_char(s:sub(p + 1, p + 1)) do p = utf8_next(s, p) end
		while p < #s and word_char(s:sub(p + 1, p + 1)) do p = utf8_next(s, p) end
	else
		while p > 0 and not word_char(s:sub(utf8_prev(s, p) + 1, p)) do p = utf8_prev(s, p) end
		while p > 0 and word_char(s:sub(utf8_prev(s, p) + 1, p)) do p = utf8_prev(s, p) end
		if not word_char(s:sub(p + 1, p + 1)) then p = p + 1 end
	end
	return p
end
local function text_width(el, text, style)
	local f = Scintilla._style_font(el, Element.state(el), tonumber(style) or 32)
	return f:measure(tostring(text or ""))
end

local wrap_fields = { [2460] = "wrap_flags", [2462] = "wrap_flags_location", [2464] = "wrap_indent", [2472] = "wrap_indent_mode" }

local settings = { [2035] = "buffered_draw", [2611] = "font_quality", [2130] = "hscrollbar", [2280] = "vscrollbar",
		[2037] = "code_page", [2371] = "popup_mode", [2516] = "scroll_width_tracking", [2031] = "eol_mode",
		[2655] = "caret_line_always", [2525] = "extra_ascent", [2527] = "extra_descent", [2040] = "marker_symbol" }

function M.send(el, msg, w, l)
	local st = st_of(el)
	local d = st.data
	d._element_state = st
	local raw_w = w
	w = tonumber(w) or 0
	local text = d.text
	local wrapped = (d.wrap or 0) ~= 0
	if msg == 2269 then return d.wrap or 0 end

	if wrap_fields[msg] then d[wrap_fields[msg]] = w; return 0 end
	if wrap_fields[msg - 1] then return d[wrap_fields[msg - 1]] or 0 end
	if msg == 2235 then return wrapped and #Scintilla._layout(el, st):line(w) or 1 end
	if msg == 2220 or msg == 2221 then
		if not wrapped then return math.max(0, math.min(w, d.doc:lines_total())) end
		local wrap = Scintilla._layout(el, st)
		if msg == 2220 then return wrap:visible(w) end
		local _, line = wrap:row(w); return line
	end
	if msg == 2370 then return math.max(1, math.floor(st.h / select(2, char_width(el)))) end
	if msg == 2164 or msg == 2165 then
		if wrapped then
			local wrap, margin = Scintilla._layout(el, st)
			local display, x = wrap:position(clamp(d, l))
			return msg == 2164 and x + margin or (display - (d.first_line or 0)) * wrap.ch
		end
	end
	if msg == 2022 or (msg == 2023 and wrapped) then
		local wrap, margin = Scintilla._layout(el, st)
		if msg == 2023 and (w < margin or w >= st.w or (tonumber(l) or 0) < 0 or (tonumber(l) or 0) >= st.h) then return -1 end
		return wrap:hit((d.first_line or 0) + math.floor((tonumber(l) or 0) / wrap.ch), w - margin + (wrapped and 0 or (d.x_offset or 0)))
	end
	if msg == 2613 or msg == 2232 then
		local n = wrapped and Scintilla._layout(el, st):visible(d.doc:lines_total()) or d.doc:lines_total()
		local target = msg == 2232 and (wrapped and Scintilla._layout(el, st):visible(w) or w) or w
		d.first_line = math.max(0, math.min(target, n - 1)); Element.call(el, "UPDATEVSCROLL_CB"); return 0
	end
	if msg == 2349 or msg == 2450 or msg == 2345 or msg == 2346 or msg == 2451 or msg == 2452 or msg == 2347 or msg == 2348 then
		local wrap = Scintilla._layout(el, st)
		local _, _, row = wrap:position(d.caret)
		local ending = msg == 2347 or msg == 2348 or msg == 2451 or msg == 2452
		local pos = ending and row.finish or row.start
		if (msg == 2349 or msg == 2450) and d.caret <= pos then pos = d.doc:line_start(row.line) end
		if (msg == 2451 or msg == 2452) and d.caret >= pos then pos = d.doc:line_end(row.line) end
		d.caret = pos
		if msg ~= 2450 and msg ~= 2346 and msg ~= 2452 and msg ~= 2348 then d.anchor = pos end
		Scintilla._ensure_caret_visible(el, st); return 0
	end
	if msg == 2168 then Scintilla._ensure_caret_visible(el, st); return 0 end
	if msg == 2373 then d.zoom = w; d.fonts = nil; d.wrap_cache = nil; return 0 end
	if msg == 2374 then return d.zoom or 0 end

	if settings[msg] then
		if msg == 2037 or msg == 2031 then d.doc[settings[msg]] = w
		elseif msg == 2040 then d.marker_symbol = d.marker_symbol or {}; d.marker_symbol[w] = l
		else d[settings[msg]] = w end
		return 0
	end
	if msg == 2290 or msg == 2291 then d[msg == 2290 and "fold_margin_color" or "fold_margin_hi_color"] = w ~= 0 and Scintilla._bgr_to_rgb(l) or nil; return 0 end
	if msg == 2181 then -- SETTEXT
		edit(el, st, 0, #text, tostring(l or "")); d.caret, d.anchor = 0, 0; return 0
	elseif msg == 2282 then return edit(el, st, #text, #text, tostring(l or "")) and 0 or 0 -- APPENDTEXT
	elseif msg == 2006 then return #text -- GETLENGTH
	elseif msg == 2154 then return d.doc:lines_total() -- GETLINECOUNT
	elseif msg == 2167 then return w < 0 and -1 or d.doc:line_start(w) -- POSITIONFROMLINE
	elseif msg == 2166 then return d.doc:line_from_position(w) -- LINEFROMPOSITION
	elseif msg == 2136 then return d.doc:line_end(w) -- GETLINEENDPOSITION
	elseif msg == 2008 then return d.caret -- GETCURRENTPOS
	elseif msg == 2009 then return d.anchor -- GETANCHOR
	elseif msg == 2025 then
		-- SCI_GOTOPOS always drops the selection; CARET_CB only when the caret moved
		local next = clamp(d, w)
		local moved = next ~= d.caret
		d.caret, d.anchor = next, next
		if moved then
			Scintilla._ensure_caret_visible(el, st)
			Element.call(el, "CARET_CB", line_of(text, d.caret), d.caret - line_start(text, line_of(text, d.caret)), d.caret)
		end
		return 0
	elseif msg == 2160 then d.anchor, d.caret = clamp(d, w), clamp(d, l); return 0 -- SETSEL
	elseif msg == 2143 then return math.min(d.anchor, d.caret)
	elseif msg == 2145 then return math.max(d.anchor, d.caret)
	elseif msg == 2007 then return text:byte(w + 1) or 0
	elseif msg == 2171 then d.readonly = w ~= 0; return 0
	elseif msg == 2159 then return d.doc:is_save_point() and 0 or 1
	elseif msg == 2014 then d.doc:set_save_point(); return 0
	elseif msg == 2175 then d.doc:delete_undo_history(); return 0
	elseif msg == 2174 then return d.doc:can_undo() and 1 or 0
	elseif msg == 2016 then return d.doc:can_redo() and 1 or 0
	elseif msg == 2078 then d.doc:begin_undo(); return 0
	elseif msg == 2079 then d.doc:end_undo(); return 0
	elseif msg == 2012 then d.doc:set_undo_collection(w ~= 0); return 0
	elseif msg == 2019 then return d.doc.collecting and 1 or 0
	elseif msg == 2176 or msg == 2011 then
		local pos = msg == 2176 and d.doc:undo() or d.doc:redo()
		if pos >= 0 then d.caret, d.anchor = pos, pos end
		return 0
	elseif msg == 2190 then d.target_start = clamp(d, w); return 0
	elseif msg == 2192 then d.target_end = clamp(d, w); return 0
	elseif msg == 2194 then
		local a, b = math.min(d.target_start or 0, d.target_end or 0), math.max(d.target_start or 0, d.target_end or 0)
		local value = tostring(l or ""); if edit(el, st, a, b, value) then d.target_start, d.target_end = a + #value, a + #value; return #value end; return 0
	elseif msg == 4006 then d.doc:set_lexer(tostring(l or ""), d.lexer_id); return 0
	elseif msg == 4005 then d.doc:set_keywords(w, l); return 0
	elseif msg == 4003 then d.doc:colourise(w, tonumber(l) or -1); return 0
	elseif msg == 4004 then d.properties[tostring(raw_w)] = tostring(l or ""); return 0
	elseif msg == 2010 then return Scintilla._style_at(st, w)
	elseif msg == 2032 then d.doc:start_styling(clamp(d, w)); return 0
	elseif msg == 2033 then d.doc:set_style_for(w, tonumber(l) or 0); return 0
	elseif msg == 2051 then d.style_fore[w] = Scintilla._bgr_to_rgb(l); d.style[w] = d.style_fore[w]; return 0
	elseif msg == 2052 then d.style_back[w] = Scintilla._bgr_to_rgb(l); return 0
	elseif msg == 2053 then d.style_bold[w] = (l or 0) ~= 0; d.fonts = nil; d.wrap_cache = nil; return 0
	elseif msg == 2054 then d.style_italic[w] = (l or 0) ~= 0; d.fonts = nil; d.wrap_cache = nil; return 0
	elseif msg == 2055 then d.style_size[w] = tonumber(l); d.fonts = nil; d.wrap_cache = nil; return 0
	elseif msg == 2056 then d.style_face[w] = tostring(l or ""); d.fonts = nil; d.wrap_cache = nil; return 0
	elseif msg == 2050 then Scintilla._style_clear(st); return 0
	elseif msg == 2242 then d.margin_width[w] = math.max(0, tonumber(l) or 0); return 0
	elseif msg == 2240 then d.margin_type[w] = l; return 0
	elseif msg == 2244 then d.margin_mask[w] = l; return 0
	elseif msg == 2155 then d.margin_left = w; return 0
	elseif msg == 2157 then d.margin_right = w; return 0
	elseif msg == 2275 then return wrapped and 0 or (d.scroll_width or 0)
	elseif msg == 2398 then return d.x_offset or 0
	elseif msg == 2397 then d.x_offset = wrapped and 0 or math.max(0, w); Element.call(el, "UPDATEHSCROLL_CB"); return 0
	elseif msg == 2152 then return d.first_line or 0
	elseif msg == 2164 then
		local p = clamp(d, l)
		return visual_column(el, text, p, d.tab_width) * char_width(el) - (d.x_offset or 0) + (d.margin_width[0] or 0) + (d.margin_width[1] or 0)
	elseif msg == 2165 then
		-- POINTYFROMPOSITION / TEXTHEIGHT: lines are the font's height apart
		return (line_of(text, clamp(d, l)) - (d.first_line or 0)) * select(2, char_width(el))
	elseif msg == 2279 then return select(2, char_width(el))
	elseif msg == 2264 then d.dwell_time = tonumber(w) or 10000000; return 0 -- SETMOUSEDWELLTIME
	elseif msg == 2265 then return d.dwell_time or 10000000 -- GETMOUSEDWELLTIME
	elseif msg == 2276 then return text_width(el, l, w)
	elseif msg == 2023 then -- POSITIONFROMPOINTCLOSE; l is y, w is x
		local cw, ch = char_width(el); local line = math.max(0, math.min(line_count(text) - 1, (d.first_line or 0) + math.floor((tonumber(l) or 0) / ch)))
		local margin = (d.margin_width[0] or 0) + (d.margin_width[1] or 0) + 4
		local target = math.max(0, math.floor(((w or 0) + (d.x_offset or 0) - margin) / cw))
		local p, i, col = line_start(text, line), line_start(text, line) + 1, 0
		while i <= line_end(text, line) and col < target do local b = text:byte(i); col = col + (b == 9 and (d.tab_width - col % d.tab_width) or 1); i = i + utf8_size(b) end
		return math.min(i - 1, line_end(text, line))
	elseif msg == 2266 then return word_boundary(text, clamp(d, w), false)
	elseif msg == 2267 then return word_boundary(text, clamp(d, w), true)
	elseif msg == 2043 then return d.doc:marker_add(w, tonumber(l) or 0)
	elseif msg == 2041 then d.marker_fore[w] = Scintilla._bgr_to_rgb(l); return 0
	elseif msg == 2042 then d.marker_back[w] = Scintilla._bgr_to_rgb(l); return 0
	elseif msg == 2045 then d.doc:marker_delete_all(w); return 0
	elseif msg == 2044 then d.doc:marker_delete(w, tonumber(l) or 0); return 0
	elseif msg == 2046 then return d.doc:marker_get(w)
	elseif msg == 2047 then return d.doc:marker_next(w, tonumber(l) or 0, 1)
	elseif msg == 2048 then return d.doc:marker_next(w, tonumber(l) or 0, -1)
	elseif msg == 2017 then return d.doc:marker_line_from_handle(w)
	elseif msg == 2018 then d.doc:marker_delete_handle(w); return 0
	elseif msg == 2080 then d.indic_style[w] = l; return 0
	elseif msg == 2082 then d.indic_fore[w] = Scintilla._bgr_to_rgb(l); return 0
	elseif msg == 2510 then d.indic_under[w] = l ~= 0; return 0
	elseif msg == 2500 then d.indicator_current = w; return 0
	elseif msg == 2504 then d.doc:indicator_fill(d.indicator_current or 0, w, tonumber(l) or 0, d.indicator_value); return 0
	elseif msg == 2505 then d.doc:indicator_clear(d.indicator_current or 0, w, tonumber(l) or 0); return 0
	elseif msg == 2631 then return d.technology or 0
	elseif msg == 2630 then d.technology = w; return 0
	elseif msg == 2036 then d.tab_width = math.max(1, w); return 0
	elseif msg == 2188 then d.caret_width = math.max(0, w); return 0
	elseif msg == 2274 then d.scroll_width = math.max(0, w); return 0
	elseif msg == 2268 then d.wrap = w; if w ~= 0 then d.x_offset = 0 end; return 0
	elseif msg == 2096 then d.caret_line_visible = w ~= 0; return 0
	elseif msg == 2098 then d.caret_line_back = Scintilla._bgr_to_rgb(w); return 0
	elseif msg == 2067 then d.sel_fore = Scintilla._bgr_to_rgb(l); return 0
	elseif msg == 2068 then d.sel_back = Scintilla._bgr_to_rgb(l); return 0
	elseif msg == 2069 then d.caret_fore = Scintilla._bgr_to_rgb(w); return 0
	elseif msg == 2357 then return d.doc.handle
	elseif msg == 2375 then local doc = Document.new(); doc:add_ref(); return doc.handle
	elseif msg == 2358 then
		local doc = (l == nil or l == 0) and Document.new() or Document.from_handle(l)
		if doc then View.attach(el, st, doc) end
		return 0
	elseif msg == 2376 or msg == 2377 then
		local doc = Document.from_handle(l)
		if doc then if msg == 2376 then doc:add_ref() else doc:release() end end
		return 0
	elseif msg == 4001 then d.lexer_id = w; return 0
	elseif msg == 2100 then
		d.autoc.visible, d.autoc.items, d.autoc.current, d.autoc.pos = true, {}, 1, d.caret
		for item in tostring(l or ""):gmatch("[^" .. (d.autoc.separator or " ") .. "]+") do d.autoc.items[#d.autoc.items + 1] = item end
		return 0
	elseif msg == 2102 then d.autoc.visible = false; return 0
	elseif msg == 2106 then d.autoc.separator = string.char(w == 0 and 32 or w); return 0
	elseif msg == 2108 then
		for i, item in ipairs(d.autoc.items) do if item == tostring(l or "") then d.autoc.current = i; break end end
		return 0
	elseif msg == 2445 then return math.max(0, (d.autoc.current or 1) - 1)
	elseif msg == 2107 then return #d.autoc.items
	elseif msg == 2200 then d.calltip = tostring(l or ""); return 0
	elseif msg == 2201 then d.calltip = nil; return 0
	elseif msg == 2202 then return d.calltip and 1 or 0
	elseif msg == 2540 then d.annotations[w] = tostring(l or ""); return 0
	elseif msg == 2542 then d.annotation_style[w] = l; return 0
	elseif msg == 2548 then d.annotation_visible = w; return 0
	end
	return 0
end
function M.sends(el, msg, w, text) return M.send(el, msg, w, text) end
return M
