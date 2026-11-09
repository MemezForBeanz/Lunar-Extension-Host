-- A small, deterministic Scintilla-compatible code editor.
-- @module core.imgui.widgets.scintilla
local Classes = require("core.imgui.Classes")
local Element = require("core.imgui.Element")
local Fonts = require("core.imgui.Fonts")
local iup = require("core.imgui.iup")

local M = {}
local function yes(v) return tostring(v or ""):upper() == "YES" or v == true end
local function attr(e, n) return Element.getAttribute(e, n) end
local function line_start(s, line)
	local p = 1
	for _ = 1, line do p = s:find("\n", p, true); if not p then return #s end; p = p + 1 end
	return p - 1
end
local function line_from(s, pos) return select(2, s:sub(1, pos):gsub("\n", "\n")) end
local function line_end(s, line)
	local p = line_start(s, line); local n = s:find("\n", p + 1, true)
	return n and n - 1 or #s
end
local function clamp(st, p) return math.max(0, math.min(#st.data.text, math.floor(p or 0))) end
local function color(v) return v or "0 0 0" end
local function bgr_to_rgb(v)
	v = tonumber(v) or 0
	return string.format("%d %d %d", v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256)
end
local function tokenize(st)
	local text, lang, words = st.data.text, st.data.lexer or "null", st.data.keywords or {}
	local styles = {}
	local keyword = {}
	for _, list in pairs(words) do for word in tostring(list):gmatch("[%w_]+") do keyword[word] = true end end
	local pos = 1
	while pos <= #text do
		local a, b, style
		local c = text:sub(pos, pos)
		if c == "\"" or c == "'" or c == "`" then
			local q = c; a = pos; b = text:find(q, pos + 1, true) or #text; style = 6
		elseif text:sub(pos, pos + 1) == "--" or text:sub(pos, pos + 1) == "//" or c == "#" then
			a = pos; b = text:find("\n", pos, true) or #text; style = 1
		else
			local ws, we = text:find("[%a_][%w_]*", pos)
			if ws == pos then a, b = ws, we; style = keyword[text:sub(a, b)] and 5 or 0
			else
				local ns, ne = text:find("%d+%.?%d*", pos)
				if ns == pos then a, b, style = ns, ne, 4 end
			end
		end
		if a then styles[#styles + 1] = { a - 1, b, style }; pos = b + 1 else pos = pos + 1 end
	end
	st.data.styles = styles
end
local function style_at(st, p)
	for _, r in ipairs(st.data.styles or {}) do if p >= r[1] and p < r[2] then return r[3] end end
	return 0
end
local function notify_change(e, st)
	tokenize(st)
	Element.call(e, "VALUECHANGED_CB")
end
local function set_value(e, st, v)
	st.data.text = tostring(v or "")
	st.data.caret, st.data.anchor = #st.data.text, #st.data.text
	st.data.modified = true
	tokenize(st)
	return false
end
local function replace(st, a, b, value)
	st.data.text = st.data.text:sub(1, a) .. value .. st.data.text:sub(b + 1)
	st.data.caret, st.data.anchor = a + #value, a + #value
	st.data.modified = true
end
local function emit_action(e, st, insert, a, b)
	if st.data.readonly or yes(attr(e, "READONLY")) then return false end
	local proposed = st.data.text:sub(1, a) .. insert .. st.data.text:sub(b + 1)
	local r = Element.call(e, "ACTION", insert ~= "" and insert:byte() or 0, 0, #insert, insert)
	if r == iup.IGNORE then return false end
	replace(st, a, b, insert); notify_change(e, st)
	return true, proposed
end
local function natural(e, st, L)
	local f = L.font(e); local cw, ch = f:charsize()
	local cols = tonumber(attr(e, "VISIBLECOLUMNS")) or 20
	local lines = tonumber(attr(e, "VISIBLELINES")) or 4
	return cols * cw + (tonumber(attr(e, "MARGINWIDTH0")) or 0) + 8, lines * ch + 4
end
local function draw(e, st, dc, rt)
	local f = Fonts.forElement(e); local cw, ch = f:charsize()
	local bg, fg = attr(e, "BGCOLOR") or "255 255 255", attr(e, "FGCOLOR") or "0 0 0"
	dc:fill(st.x, st.y, st.w, st.h, bg)
	dc:clip_push(st.x, st.y, st.w, st.h)
	local first = st.data.first_line or 0
	local margin = tonumber(st.data.margin_width[0] or 0) or 0
	local text = st.data.text
	local lines = {}
	for line in (text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
	local caret_line = line_from(text, st.data.caret)
	for i = first + 1, math.min(#lines, first + math.ceil(st.h / ch) + 1) do
		local y = st.y + (i - first - 1) * ch
		if st.data.caret_line_visible and i - 1 == caret_line then dc:fill(st.x, y, st.w, ch, attr(e, "CARETLINEBACKCOLOR") or "240 240 240") end
		if margin > 0 then dc:text(tostring(i), st.x + 4, y, margin - 8, ch, attr(e, "MARGINFGCOLOR") or "120 120 120", f, { align = "right", clip = true }) end
		local p = line_start(text, i - 1)
		local x = st.x + margin + 4 - (st.data.x_offset or 0)
		local line = lines[i]
		local at = 1
		while at <= #line do
			local c, q = line:sub(at, at + 3), at + 1
			local n = line:byte(at)
			if n and n >= 128 then while line:byte(q) and line:byte(q) >= 128 and line:byte(q) < 192 do q = q + 1 end; c = line:sub(at, q - 1) end
			local style = style_at(st, p + at - 1)
			local run = c
			local nextat = q
			while nextat <= #line and style_at(st, p + nextat - 1) == style do
				local byte = line:byte(nextat)
				local size = byte and byte < 128 and 1 or byte and byte < 224 and 2 or byte and byte < 240 and 3 or 4
				local nq = math.min(#line + 1, nextat + size)
				run = run .. line:sub(nextat, nq - 1); nextat = nq
			end
			local sc = st.data.style[style] or fg
			dc:text(run, x, y, math.max(cw, st.w - (x - st.x)), ch, sc, f, { clip = true })
			x = x + f:measure(run); at = nextat
		end
	end
	local a, b = math.min(st.data.anchor, st.data.caret), math.max(st.data.anchor, st.data.caret)
	if a ~= b then
		local ln, col = line_from(text, a), a - line_start(text, line_from(text, a))
		dc:fill(st.x + margin + 4 + col * cw, st.y + (ln - first) * ch, math.max(cw, (b - a) * cw), ch, attr(e, "SELBACK") or "100 140 220 100")
	end
	if rt and rt.focused and rt.focused() == e then
		local ln, col = line_from(text, st.data.caret), st.data.caret - line_start(text, line_from(text, st.data.caret))
		dc:line(st.x + margin + 4 + col * cw - (st.data.x_offset or 0), st.y + (ln - first) * ch,
			st.x + margin + 4 + col * cw - (st.data.x_offset or 0), st.y + (ln - first + 1) * ch, attr(e, "CARETCOLOR") or fg, 1)
	end
	dc:clip_pop()
end
local function event(e, st, ev, rt)
	if ev.type == "focus" or ev.type == "blur" then return true end
	if ev.type == "press" then
		local f = Fonts.forElement(e); local cw = f:charsize()
		local line = math.max(0, (st.data.first_line or 0) + math.floor((ev.ly or 0) / f:charsize()))
		local col = math.max(0, math.floor(((ev.lx or 0) - (st.data.margin_width[0] or 0) + (st.data.x_offset or 0)) / cw))
		st.data.caret = math.min(line_end(st.data.text, line), line_start(st.data.text, line) + col)
		st.data.anchor = ev.mods and ev.mods.shift and st.data.anchor or st.data.caret
		if rt and rt.capture then rt.capture(e) end
		return true
	elseif ev.type == "char" and not st.data.readonly and not yes(attr(e, "READONLY")) then
		local a, b = math.min(st.data.anchor, st.data.caret), math.max(st.data.anchor, st.data.caret)
		emit_action(e, st, ev.char, a, b); return true
	elseif ev.type == "key" then
		local k = iup.XkeyBase(ev.key); local ctrl = ev.mods and ev.mods.ctrl or iup.isCtrlXkey(ev.key)
		local a, b = math.min(st.data.anchor, st.data.caret), math.max(st.data.anchor, st.data.caret)
		if k == iup.K_LEFT then st.data.caret = math.max(0, st.data.caret - 1)
		elseif k == iup.K_RIGHT then st.data.caret = math.min(#st.data.text, st.data.caret + 1)
		elseif k == iup.K_HOME then st.data.caret = line_start(st.data.text, line_from(st.data.text, st.data.caret))
		elseif k == iup.K_END then st.data.caret = line_end(st.data.text, line_from(st.data.text, st.data.caret))
		elseif k == iup.K_BS and a ~= b then emit_action(e, st, "", a, b)
		elseif k == iup.K_BS and st.data.caret > 0 then emit_action(e, st, "", st.data.caret - 1, st.data.caret)
		elseif k == iup.K_DEL then emit_action(e, st, "", a, b == a and math.min(#st.data.text, b + 1) or b)
		elseif k == iup.K_CR then emit_action(e, st, "\n", a, b)
		else return false end
		if not ev.mods or not ev.mods.shift then st.data.anchor = st.data.caret end
		Element.call(e, "CARET_CB", line_from(st.data.text, st.data.caret), st.data.caret - line_start(st.data.text, line_from(st.data.text, st.data.caret)))
		return true
	end
	return false
end
local defaults = { BORDER = "YES", CANFOCUS = "YES", BGCOLOR = "255 255 255", FGCOLOR = "0 0 0", VISIBLECOLUMNS = "20", VISIBLELINES = "4", CURSOR = "IBEAM" }
Classes.define{
	name = "scintilla", children = 0, focusable = true, defaults = defaults, natural = natural, draw = draw, event = event,
	set = { VALUE = set_value },
	get = {
		VALUE = function(e, st) return st.data.text end,
		COUNT = function(e, st) return #st.data.text end,
		CARETPOS = function(e, st) return st.data.caret end,
		CARET = function(e, st) return st.data.caret end,
		SELECTIONSTART = function(e, st) return math.min(st.data.anchor, st.data.caret) end,
		SELECTIONEND = function(e, st) return math.max(st.data.anchor, st.data.caret) end,
	},
	callbacks = { ACTION = true, VALUECHANGED_CB = true, CARET_CB = true, DWELL_CB = true, UPDATECONTENT_CB = true, UPDATEVSCROLL_CB = true, UPDATEHSCROLL_CB = true },
	create = function(e, st)
		st.data.text = st.data.text or tostring(Element.own(e, "VALUE") or "")
		st.data.caret, st.data.anchor = #st.data.text, #st.data.text
		st.data.lexer, st.data.keywords, st.data.styles, st.data.style = "null", {}, {}, {}
		st.data.margin_width = { [0] = 0, [1] = 0, [2] = 0, [3] = 0, [4] = 0 }
		st.data.first_line, st.data.x_offset, st.data.modified = 0, 0, false
		tokenize(st)
	end,
}

M._tokenize = tokenize
M._bgr_to_rgb = bgr_to_rgb
M._style_at = style_at
return M
