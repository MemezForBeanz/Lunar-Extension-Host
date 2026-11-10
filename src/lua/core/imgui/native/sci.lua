-- Virtual replacement for the small `sci` Lua module used by CodeView.
-- @module sci
local Element = require("core.imgui.Element")
local Scintilla = require("core.imgui.widgets.scintilla")
local Fonts = require("core.imgui.Fonts")

local M = {}
local function st_of(el)
	local st = Element.state(el)
	if not st or st.classname ~= "scintilla" then error("sci: expected scintilla handle", 3) end
	return st
end
local function font_size(el)
	local _, ch = Fonts.forElement(el):charsize()
	return ch
end
local function line_start(s, line)
	local p = 1
	for _ = 1, line do p = s:find("\n", p, true); if not p then return #s end; p = p + 1 end
	return p - 1
end
local function line_end(s, line)
	local p = line_start(s, line); local n = s:find("\n", p + 1, true)
	return n and n - 1 or #s
end
local function lines(s) return select(2, s:gsub("\n", "\n")) + 1 end
local function word_boundary(s, p, right)
	local function word(c) return c and c:match("[%w_]") ~= nil end
	if right then
		while p < #s and not word(s:sub(p + 1, p + 1)) do p = p + 1 end
		while p < #s and word(s:sub(p + 1, p + 1)) do p = p + 1 end
	else
		while p > 0 and not word(s:sub(p, p)) do p = p - 1 end
		while p > 0 and word(s:sub(p, p)) do p = p - 1 end
		if not word(s:sub(p + 1, p + 1)) then p = p + 1 end
	end
	return p
end
function M.send(el, msg, w, l)
	local st = st_of(el); local d = st.data; local text = d.text
	w = tonumber(w) or 0
	if type(l) ~= "string" then l = tonumber(l) or 0 end
	if msg == 2181 then d.text = tostring(l or ""); d.caret, d.anchor = #d.text, #d.text; Scintilla._tokenize(st); Element.call(el, "VALUECHANGED_CB"); return 0
	elseif msg == 2282 then d.text = d.text .. tostring(l or ""); Scintilla._tokenize(st); Element.call(el, "VALUECHANGED_CB"); return 0
	elseif msg == 2006 then return #d.text
	elseif msg == 2154 then return lines(d.text)
	elseif msg == 2167 then return line_start(d.text, w)
	elseif msg == 2166 then local p = math.max(0, math.min(#d.text, w)); return select(2, d.text:sub(1, p):gsub("\n", "\n"))
	elseif msg == 2136 then return line_end(d.text, w)
	elseif msg == 2008 then return d.caret
	elseif msg == 2009 then return d.anchor
	elseif msg == 2025 then d.caret = math.max(0, math.min(#d.text, w)); d.anchor = d.caret; return 0
	elseif msg == 2160 then d.anchor, d.caret = math.max(0, math.min(#d.text, w)), math.max(0, math.min(#d.text, l)); return 0
	elseif msg == 2143 then return math.min(d.anchor, d.caret)
	elseif msg == 2145 then return math.max(d.anchor, d.caret)
	elseif msg == 2007 then return d.text:byte(w + 1) or 0
	elseif msg == 2171 then d.readonly = w ~= 0; return 0
	elseif msg == 2159 then return d.modified and 1 or 0
	elseif msg == 2014 then d.modified = false; return 0
	elseif msg == 2175 then d.undo = {}; return 0
	elseif msg == 2190 then d.target_start = w; return 0
	elseif msg == 2192 then d.target_end = w; return 0
	elseif msg == 2194 then
		if not d.readonly then
			local value = tostring(l or ""); d.text = d.text:sub(1, d.target_start) .. value .. d.text:sub(d.target_end + 1)
			d.caret, d.anchor = d.target_start + #value, d.target_start + #value; d.modified = true; Scintilla._tokenize(st); Element.call(el, "VALUECHANGED_CB")
		end
		return #tostring(l or "")
	elseif msg == 4006 then d.lexer = tostring(l or ""); Scintilla._tokenize(st); return 0
	elseif msg == 4005 then d.keywords[w] = tostring(l or ""); Scintilla._tokenize(st); return 0
	elseif msg == 4004 then return 0
	elseif msg == 4003 then Scintilla._tokenize(st); return 0
	elseif msg == 2010 then return Scintilla._style_at and Scintilla._style_at(st, w) or 0
	elseif msg == 2032 then d.styling_pos = w; return 0
	elseif msg == 2033 then d.style_ranges = d.style_ranges or {}; d.style_ranges[#d.style_ranges + 1] = { d.styling_pos, d.styling_pos + w, l }; d.styling_pos = d.styling_pos + w; return 0
	elseif msg == 2051 then d.style[w] = Scintilla._bgr_to_rgb(l); return 0
	elseif msg == 2052 then d.style_bg = d.style_bg or {}; d.style_bg[w] = Scintilla._bgr_to_rgb(l); return 0
	-- Style fonts (SCI_STYLESETBOLD/SIZE/FONT); STYLE_DEFAULT is 32, and STYLECLEARALL
	-- copies it to every style, as Scintilla does.
	elseif msg == 2053 then d.style_bold = d.style_bold or {}; d.style_bold[w] = (l or 0) ~= 0; d.fonts = nil; return 0
	elseif msg == 2055 then d.style_size = d.style_size or {}; d.style_size[w] = tonumber(l); d.fonts = nil; return 0
	elseif msg == 2056 then d.style_face = d.style_face or {}; d.style_face[w] = tostring(l or ""); d.fonts = nil; return 0
	elseif msg == 2050 then
		for _, key in ipairs({ "style_bold", "style_size", "style_face" }) do
			local t = d[key]
			if t and t[32] ~= nil then
				local keep = t[32]
				for k in pairs(t) do t[k] = nil end
				t[32] = keep
			end
		end
		d.fonts = nil
		return 0
	elseif msg == 2242 then d.margin_width[w] = l; return 0
	elseif msg == 2240 then d.margin_type = d.margin_type or {}; d.margin_type[w] = l; return 0
	elseif msg == 2275 then return d.scroll_width or 0
	elseif msg == 2398 then return d.x_offset or 0
	elseif msg == 2397 then d.x_offset = math.max(0, w); return 0
	elseif msg == 2152 then return d.first_line or 0
	elseif msg == 2613 then d.first_line = math.max(0, w); return 0
	elseif msg == 2370 then return math.max(1, tonumber(Element.getAttribute(el, "VISIBLELINES")) or 4)
	elseif msg == 2220 then return math.max(0, math.min(w, lines(d.text) - 1))
	elseif msg == 2232 then return 0
	elseif msg == 2164 then return (w or 0) * font_size(el)
	elseif msg == 2165 then local line = math.max(0, math.min(lines(d.text) - 1, l)); return (line - (d.first_line or 0)) * font_size(el)
	elseif msg == 2279 then return font_size(el)
	elseif msg == 2276 then return #(tostring(l or "")) * font_size(el)
	elseif msg == 2023 then return math.max(0, math.min(#d.text, (l or 0) / math.max(1, font_size(el))))
	elseif msg == 2266 then return word_boundary(d.text, math.max(0, math.min(#d.text, w)), false)
	elseif msg == 2267 then return word_boundary(d.text, math.max(0, math.min(#d.text, w)), true)
	elseif msg == 2504 or msg == 2505 or msg == 2080 or msg == 2082 or msg == 2510 or msg == 2500 then return 0
	elseif msg == 2043 then d.markers = d.markers or {}; d.markers[l] = w; return 0
	elseif msg == 2045 then d.markers = {}; return 0
	elseif msg == 2631 then return 0 end
	return 0
end
function M.sends(el, msg, w, text)
	return M.send(el, msg, w, text)
end
return M
