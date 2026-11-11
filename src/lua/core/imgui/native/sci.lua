-- Scintilla message compatibility used by CodeView and LSP integrations.
-- Positions are byte offsets, as in Scintilla (SC_CP_UTF8).
local Element = require("core.imgui.Element")
local Scintilla = require("core.imgui.widgets.scintilla")
local Fonts = require("core.imgui.Fonts")

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
local function font(el) return Fonts.forElement(el) end
local function char_width(el) return font(el):charsize() end
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
local function snapshot(d)
	return { text = d.text, caret = d.caret, anchor = d.anchor, modified = d.modified }
end
local function restore(d, x)
	d.text, d.caret, d.anchor, d.modified = x.text, x.caret, x.anchor, x.modified
	Scintilla._tokenize(d._element_state)
end
local function changed(el, st)
	Scintilla._tokenize(st)
	Element.call(el, "VALUECHANGED_CB")
end
local function edit(el, st, a, b, value)
	local d = st.data
	if d.readonly then return false end
	d.undo = d.undo or {}
	d.redo = {}
	d.undo[#d.undo + 1] = snapshot(d)
	d.text = d.text:sub(1, a) .. value .. d.text:sub(b + 1)
	d.caret, d.anchor, d.modified = a + #value, a + #value, true
	changed(el, st)
	Element.call(el, "CARET_CB", line_of(d.text, d.caret), d.caret - line_start(d.text, line_of(d.text, d.caret)))
	return true
end
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

function M.send(el, msg, w, l)
	local st, d = st_of(el), st_of(el).data
	d._element_state = st
	w = tonumber(w) or 0
	local text = d.text
	if msg == 2181 then -- SETTEXT
		d.text, d.caret, d.anchor, d.modified = tostring(l or ""), 0, 0, false
		d.undo, d.redo = {}, {}; Scintilla._tokenize(st); Element.call(el, "VALUECHANGED_CB"); return 0
	elseif msg == 2282 then return edit(el, st, #text, #text, tostring(l or "")) and 0 or 0 -- APPENDTEXT
	elseif msg == 2006 then return #text -- GETLENGTH
	elseif msg == 2154 then return line_count(text) -- GETLINECOUNT
	elseif msg == 2167 then return line_start(text, w) -- POSITIONFROMLINE
	elseif msg == 2166 then return line_of(text, w) -- LINEFROMPOSITION
	elseif msg == 2136 then return line_end(text, w) -- GETLINEENDPOSITION
	elseif msg == 2008 then return d.caret -- GETCURRENTPOS
	elseif msg == 2009 then return d.anchor -- GETANCHOR
	elseif msg == 2025 then
		local next = clamp(d, w)
		if next ~= d.caret then
			d.caret, d.anchor = next, next
			Element.call(el, "CARET_CB", line_of(text, d.caret), d.caret - line_start(text, line_of(text, d.caret)), d.caret)
		end
		return 0
	elseif msg == 2160 then d.anchor, d.caret = clamp(d, w), clamp(d, l); return 0 -- SETSEL
	elseif msg == 2143 then return math.min(d.anchor, d.caret)
	elseif msg == 2145 then return math.max(d.anchor, d.caret)
	elseif msg == 2007 then return text:byte(w + 1) or 0
	elseif msg == 2171 then d.readonly = w ~= 0; return 0
	elseif msg == 2159 then return d.modified and 1 or 0
	elseif msg == 2014 then d.modified = false; return 0
	elseif msg == 2175 then d.undo, d.redo = {}, {}; return 0
	elseif msg == 2174 then return d.undo and #d.undo > 0 and 1 or 0
	elseif msg == 2016 then return d.redo and #d.redo > 0 and 1 or 0
	elseif msg == 2176 then
		if d.undo and #d.undo > 0 then d.redo[#d.redo + 1] = snapshot(d); restore(d, table.remove(d.undo)); Element.call(el, "VALUECHANGED_CB") end
		return 0
	elseif msg == 2011 then
		if d.redo and #d.redo > 0 then d.undo[#d.undo + 1] = snapshot(d); restore(d, table.remove(d.redo)); Element.call(el, "VALUECHANGED_CB") end
		return 0
	elseif msg == 2190 then d.target_start = clamp(d, w); return 0
	elseif msg == 2192 then d.target_end = clamp(d, w); return 0
	elseif msg == 2194 then
		local a, b = math.min(d.target_start or 0, d.target_end or 0), math.max(d.target_start or 0, d.target_end or 0)
		local value = tostring(l or ""); if edit(el, st, a, b, value) then d.target_start, d.target_end = a + #value, a + #value; return #value end; return 0
	elseif msg == 4006 then d.lexer = tostring(l or ""); Scintilla._tokenize(st); return 0
	elseif msg == 4005 then d.keywords[w] = tostring(l or ""); Scintilla._tokenize(st); return 0
	elseif msg == 4003 then Scintilla._tokenize(st); return 0
	elseif msg == 4004 then d.properties[tostring(w)] = tostring(l or ""); return 0
	elseif msg == 2010 then return Scintilla._style_at(st, w)
	elseif msg == 2032 then d.styling_pos = clamp(d, w); return 0
	elseif msg == 2033 then d.style_ranges[#d.style_ranges + 1] = { d.styling_pos, d.styling_pos + w, tonumber(l) or 0 }; d.styling_pos = d.styling_pos + w; return 0
	elseif msg == 2051 then d.style_fore[w] = Scintilla._bgr_to_rgb(l); d.style[w] = d.style_fore[w]; return 0
	elseif msg == 2052 then d.style_back[w] = Scintilla._bgr_to_rgb(l); return 0
	elseif msg == 2053 then d.style_bold[w] = w ~= 0 and (l or 0) ~= 0 or d.style_bold[w]; d.fonts = nil; return 0
	elseif msg == 2054 then d.style_italic[w] = (l or 0) ~= 0; return 0
	elseif msg == 2055 then d.style_size[w] = tonumber(l); d.fonts = nil; return 0
	elseif msg == 2056 then d.style_face[w] = tostring(l or ""); d.fonts = nil; return 0
	elseif msg == 2050 then Scintilla._style_clear(st); return 0
	elseif msg == 2242 then d.margin_width[w] = math.max(0, tonumber(l) or 0); return 0
	elseif msg == 2240 then d.margin_type[w] = l; return 0
	elseif msg == 2244 then d.margin_mask[w] = l; return 0
	elseif msg == 2155 then d.margin_left = w; return 0
	elseif msg == 2157 then d.margin_right = w; return 0
	elseif msg == 2275 then return d.scroll_width or 0
	elseif msg == 2398 then return d.x_offset or 0
	elseif msg == 2397 then d.x_offset = math.max(0, w); Element.call(el, "UPDATEHSCROLL_CB"); return 0
	elseif msg == 2152 then return d.first_line or 0
	elseif msg == 2613 then d.first_line = math.max(0, math.min(w, math.max(0, line_count(text) - 1))); Element.call(el, "UPDATEVSCROLL_CB"); return 0
	elseif msg == 2370 then return math.max(1, math.floor((tonumber(tostring(Element.getAttribute(el, "RASTERSIZE") or ""):match("x(%d+)")) or 0) / char_width(el)))
	elseif msg == 2220 then return math.max(0, math.min(w, line_count(text) - 1))
	elseif msg == 2232 then d.first_line = math.max(0, math.min(w, math.max(0, line_count(text) - (M.send(el, 2370) or 1)))); return 0
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
	elseif msg == 2043 then d.markers[l] = w; return 0
	elseif msg == 2041 then d.marker_fore[w] = Scintilla._bgr_to_rgb(l); return 0
	elseif msg == 2042 then d.marker_back[w] = Scintilla._bgr_to_rgb(l); return 0
	elseif msg == 2045 then d.markers = {}; return 0
	elseif msg == 2080 then d.indic_style[w] = l; return 0
	elseif msg == 2082 then d.indic_fore[w] = Scintilla._bgr_to_rgb(l); return 0
	elseif msg == 2510 then d.indic_under[w] = l ~= 0; return 0
	elseif msg == 2500 then d.indicator_current = w; return 0
	elseif msg == 2504 then d.indicators[d.indicator_current] = d.indicators[d.indicator_current] or {}; d.indicators[d.indicator_current][#d.indicators[d.indicator_current] + 1] = { w, w + (l or 0) }; return 0
	elseif msg == 2505 then d.indicators[d.indicator_current] = {}; return 0
	elseif msg == 2631 then return d.technology or 0
	elseif msg == 2630 then d.technology = w; return 0
	elseif msg == 2036 then d.tab_width = math.max(1, w); return 0
	elseif msg == 2188 then d.caret_width = math.max(0, w); return 0
	elseif msg == 2274 then d.scroll_width = math.max(0, w); return 0
	elseif msg == 2268 then d.wrap = w; return 0
	elseif msg == 2096 then d.caret_line_visible = w ~= 0; return 0
	elseif msg == 2098 then d.caret_line_back = Scintilla._bgr_to_rgb(w); return 0
	elseif msg == 2067 then d.sel_fore = Scintilla._bgr_to_rgb(l); return 0
	elseif msg == 2068 then d.sel_back = Scintilla._bgr_to_rgb(l); return 0
	elseif msg == 2069 then d.caret_fore = Scintilla._bgr_to_rgb(w); return 0
	elseif msg == 2357 then d.document = d.document or {}; return d.document
	elseif msg == 2375 then return {} -- independent document handle is opaque to Lua
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
