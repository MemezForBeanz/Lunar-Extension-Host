-- IUP text and multiline controls.
-- @module core.imgui.widgets.text
local Classes = require("core.imgui.Classes")
local Element = require("core.imgui.Element")
local Fonts = require("core.imgui.Fonts")
local iup = require("core.imgui.iup")

local M = {}
local function attr(e, n) return Element.getAttribute(e, n) end
local yes = Element.isTrue -- iupStrBoolean
local function pair(v)
	local a, b = tostring(v or "0x0"):match("^%s*([^xX]*)[xX]([^xX]*)")
	return tonumber(a) or 0, tonumber(b) or 0
end
local function utf8_char(s, p)
	local b = s:byte(p)
	if not b then return nil end
	local n = b < 128 and 1 or b < 224 and 2 or b < 240 and 3 or 4
	return s:sub(p, p + n - 1), p + n
end
local function utf8_encode(n)
	if n < 128 then return string.char(n)
	elseif n < 2048 then return string.char(192 + math.floor(n / 64), 128 + n % 64)
	elseif n < 65536 then return string.char(224 + math.floor(n / 4096), 128 + math.floor(n / 64) % 64, 128 + n % 64)
	else return string.char(240 + math.floor(n / 262144), 128 + math.floor(n / 4096) % 64, 128 + math.floor(n / 64) % 64, 128 + n % 64) end
end
local function previous(s, p)
	p = math.max(0, p - 1)
	while p > 0 and s:byte(p + 1) and s:byte(p + 1) >= 128 and s:byte(p + 1) < 192 do p = p - 1 end
	return p
end
local function nextpos(s, p)
	return utf8_char(s, p + 1) and (select(2, utf8_char(s, p + 1)) - 1) or #s
end
local function word_left(s, p)
	while p > 0 do
		local q = previous(s, p)
		local c = s:sub(q + 1, p)
		if not c:match("[%s%p]") then break end
		p = q
	end
	while p > 0 do
		local q = previous(s, p)
		if s:sub(q + 1, p):match("[%s%p]") then break end
		p = q
	end
	return p
end
local function word_right(s, p)
	while p < #s do
		local c, q = utf8_char(s, p + 1)
		if not c:match("[%s%p]") then break end
		p = q - 1
	end
	while p < #s do
		local c, q = utf8_char(s, p + 1)
		if c:match("[%s%p]") then break end
		p = q - 1
	end
	return p
end
local function clamp(st, p) return math.max(0, math.min(#st.data.text, math.floor(p or 0))) end
local function sorted_selection(st)
	local a, b = st.data.anchor or st.data.caret, st.data.caret
	return math.min(a, b), math.max(a, b)
end
local function line_at(s, p)
	local before = s:sub(1, p)
	local line = select(2, before:gsub("\n", "\n"))
	local start = before:match(".*\n()") or 1
	return line, p - start + 1
end
local function line_start(s, p)
	local n = s:sub(1, p):match(".*\n()")
	return n and n - 1 or 0
end
local function action(e, old, proposed, from, to)
	local c = proposed:sub(1, 1)
	local r = Element.call(e, "ACTION", c:byte() or 0, proposed)
	if r == iup.IGNORE then return nil end
	if type(r) == "number" and r >= 0 and r <= 0x10ffff then
		if r < 128 then proposed = string.char(r) else
			proposed = utf8_encode(r)
		end
	end
	return proposed
end
local function replace(e, st, from, to, insert, rt)
	if yes(attr(e, "READONLY")) then return false end
	local text = st.data.text
	insert = tostring(insert or "")
	local filter = tostring(attr(e, "FILTER") or ""):upper()
	if filter:find("UPPERCASE", 1, true) then insert = insert:upper()
	elseif filter:find("LOWERCASE", 1, true) then insert = insert:lower()
	elseif filter:find("NUMBER", 1, true) then insert = insert:gsub("[^%d%.%-]", "") end
	local mask = attr(e, "MASK")
	if mask and mask ~= "" and insert ~= "" and not insert:match("^" .. tostring(mask) .. "$") then return false end
	local nc = tonumber(attr(e, "NC")) -- 0: no limit (IUP's default)
	if nc and nc > 0 and #text - (to - from) + #insert > nc then insert = insert:sub(1, math.max(0, nc - (#text - (to - from)))) end
	local proposed = text:sub(1, from) .. insert .. text:sub(to + 1)
	proposed = action(e, text, proposed, from, to)
	if proposed == nil then return false end
	st.data.undo = st.data.undo or {}
	st.data.undo[#st.data.undo + 1] = { text = text, caret = st.data.caret, anchor = st.data.anchor }
	if #st.data.undo > 32 then table.remove(st.data.undo, 1) end
	st.data.text = proposed
	st.data.caret = from + #insert
	st.data.anchor = st.data.caret
	Element.call(e, "VALUECHANGED_CB")
	if rt and rt.redraw then rt.redraw(e) end
	return true
end
local function caret_cb(e, st)
	local line, col = line_at(st.data.text, st.data.caret)
	Element.call(e, "CARET_CB", line, col, st.data.caret)
end
local function set_value(e, st, value)
	st.data.text = tostring(value or "")
	st.data.caret, st.data.anchor = #st.data.text, #st.data.text
	return false
end
-- iTextComputeNaturalSizeMethod: one line is tmHeight tall and VISIBLECOLUMNS/10 of
-- "WWWWWWWWWW" wide, whatever the text holds; BORDER adds the Windows driver's 3 px each
-- side, SPIN a square button, and a multiline's scrollbars their system size.
local function text_natural(e, st, L)
	local font = L.font(e)
	local _, natural_h = font:charsize()
	local natural_w = font:measure("WWWWWWWWWW")
	natural_w = math.floor((tonumber(attr(e, "VISIBLECOLUMNS")) or 5) * natural_w / 10)
	local multiline = st.classname == "multiline" or yes(attr(e, "MULTILINE"))
	if multiline then natural_h = (tonumber(attr(e, "VISIBLELINES")) or 1) * natural_h end
	if yes(attr(e, "BORDER")) then natural_w, natural_h = natural_w + 6, natural_h + 6 end
	if yes(attr(e, "SPIN")) then natural_w = natural_w + natural_h end
	-- winTextSetPaddingAttrib keeps only the horizontal part (EM_SETMARGINS); vert_padding is 0.
	local hp = pair(attr(e, "PADDING"))
	natural_w = natural_w + 2 * hp
	if multiline then
		local sb = (attr(e, "SCROLLBAR") or "YES"):upper()
		local size = math.floor(17 * (require("core.imgui.Fonts").dpi or 96) / 96 + 0.5)
		if sb == "YES" or sb == "HORIZONTAL" then natural_h = natural_h + size end
		if sb == "YES" or sb == "VERTICAL" then natural_w = natural_w + size end
	end
	return natural_w, natural_h
end
local function draw(e, st, dc, rt)
	local font = Fonts.forElement(e)
	local cw, ch = font:charsize()
	local pad_x = pair(attr(e, "PADDING"))
	local pad_y = 0 -- the Windows edit control has no vertical padding (see text_natural)
	local bw = yes(attr(e, "BORDER")) and (tonumber(attr(e, "BORDERWIDTH")) or 1) or 0
	local bg = attr(e, "BGCOLOR")
	if bg then dc:fill(st.x, st.y, st.w, st.h, bg, { radius = tonumber(attr(e, "CORNERRADIUS")) or 0 }) end
	local focused = rt and rt.focused and rt.focused() == e
	local value = st.data.text
	if value == "" and attr(e, "CUEBANNER") and (not focused or true) then
		dc:text(attr(e, "CUEBANNER"), st.x + pad_x, st.y + pad_y, st.w - pad_x * 2, ch,
			attr(e, "PLACEHOLDERCOLOR") or attr(e, "FGCOLOR"), font, { clip = true })
	elseif value ~= "" then
		local shown = yes(attr(e, "PASSWORD")) and value:gsub("[^\n]", "•") or value
		local x = st.x + pad_x - (st.data.scroll_x or 0)
		local y = st.y + pad_y - (st.data.scroll_y or 0)
		local wrap = yes(attr(e, "WORDWRAP")) and st.w - pad_x * 2 - bw * 2 or nil
		dc:clip_push(st.x + bw, st.y + bw, math.max(0, st.w - bw * 2), math.max(0, st.h - bw * 2))
		dc:text(shown, x, y, math.max(0, st.w - pad_x * 2), math.max(ch, st.h - pad_y * 2), attr(e, "FGCOLOR"), font,
			{ clip = true, wrap = wrap })
		local a, b = sorted_selection(st)
		if a ~= b then
			local ls = line_start(value, st.data.caret)
			local before = value:sub(ls + 1, st.data.caret)
			local cx = x + font:measure(before)
			dc:fill(cx, y, math.max(1, font:measure(value:sub(a + 1, b))), ch, attr(e, "SELECTIONCOLOR") or "100 140 220 100")
		end
		if focused then
			local ls = line_start(value, st.data.caret)
			local cx = x + font:measure(value:sub(ls + 1, st.data.caret))
			dc:line(cx, y, cx, y + ch, attr(e, "CARETCOLOR") or attr(e, "FGCOLOR"), 1)
			if rt and rt.animate then rt.animate() end
		end
		dc:clip_pop()
	end
	if bw > 0 then dc:rect(st.x, st.y, st.w, st.h, focused and (attr(e, "FOCUSCOLOR") or attr(e, "BORDERCOLOR")) or attr(e, "BORDERCOLOR"), { thickness = bw }) end
end
local function event(e, st, ev, rt)
	local text = st.data.text
	if ev.type == "focus" or ev.type == "blur" then
		if rt and rt.redraw then rt.redraw(e) end
		return true
	elseif ev.type == "press" then
		local font = Fonts.forElement(e)
		local cw = font:charsize()
		local p = math.max(0, math.min(#text, math.floor(((ev.lx or ev.x) - (st.data.scroll_x or 0)) / cw)))
		st.data.caret = p; st.data.anchor = ev.mods and ev.mods.shift and st.data.anchor or p
		st.data.captured = true
		if rt and rt.capture then rt.capture(e) end
		caret_cb(e, st); return true
	elseif ev.type == "move" and st.data.captured then
		local cw = Fonts.forElement(e):charsize()
		st.data.caret = math.max(0, math.min(#text, math.floor(((ev.lx or ev.x) - (st.data.scroll_x or 0)) / cw)))
		caret_cb(e, st); return true
	elseif ev.type == "release" then
		st.data.captured = false
		if rt and rt.release then rt.release() end
		return true
	elseif ev.type == "char" then
		local a, b = sorted_selection(st)
		replace(e, st, a, b, ev.char, rt); caret_cb(e, st); return true
	elseif ev.type == "key" then
		local k = ev.key
		local ctrl = (ev.mods and ev.mods.ctrl) or iup.isCtrlXkey(k)
		local shift = (ev.mods and ev.mods.shift) or iup.isShiftXkey(k)
		local base = iup.XkeyBase(k)
		local low = tonumber(k) and tonumber(k) % 256 or base
		local a, b = sorted_selection(st)
		local selected_all = false
		if ctrl and (base == iup.K_c or base == iup.K_C or low == 67 or low == 99) then
			if a ~= b and rt and rt.clipboard_set then rt.clipboard_set(text:sub(a + 1, b)) end
			selected_all = true
		elseif ctrl and (base == iup.K_x or base == iup.K_X or low == 88 or low == 120) then
			if a ~= b and rt and rt.clipboard_set then rt.clipboard_set(text:sub(a + 1, b)); replace(e, st, a, b, "", rt) end
		elseif ctrl and (base == iup.K_v or base == iup.K_V or low == 86 or low == 118) then
			local clip = rt and rt.clipboard_get and rt.clipboard_get() or ""
			replace(e, st, a, b, clip, rt)
		elseif ctrl and (base == iup.K_a or base == iup.K_A or low == 65 or low == 97) then st.data.anchor, st.data.caret = 0, #text; selected_all = true
		elseif ctrl and (base == iup.K_z or base == iup.K_Z or low == 90 or low == 122) then
			local u = table.remove(st.data.undo or {})
			if u then st.data.text, st.data.caret, st.data.anchor = u.text, u.caret, u.anchor; Element.call(e, "VALUECHANGED_CB") end
		elseif base == iup.K_LEFT then st.data.caret = ctrl and word_left(text, st.data.caret) or previous(text, st.data.caret)
		elseif base == iup.K_RIGHT then st.data.caret = ctrl and word_right(text, st.data.caret) or nextpos(text, st.data.caret)
		elseif base == iup.K_HOME then st.data.caret = line_start(text, st.data.caret)
		elseif base == iup.K_END then st.data.caret = text:find("\n", st.data.caret + 1, true) and text:find("\n", st.data.caret + 1, true) - 1 or #text
		elseif base == iup.K_BS then
			if a == b then a = previous(text, a) end
			replace(e, st, a, b, "", rt)
		elseif base == iup.K_DEL then
			if a == b then b = nextpos(text, b) end
			replace(e, st, a, b, "", rt)
		else return false end
		if not shift and not selected_all then st.data.anchor = st.data.caret end
		caret_cb(e, st); if rt and rt.redraw then rt.redraw(e) end
		return true
	end
	return false
end
local common = {
	children = 0, focusable = true, natural = text_natural, draw = draw, event = event,
	-- IUP registers BORDER, PADDING ("0x0"), VISIBLECOLUMNS ("5"), VISIBLELINES and the TXT colours (attrs.lua)
	defaults = { CURSOR = "IBEAM" },
	set = {
		VALUE = set_value,
		APPEND = function(e, st, v) replace(e, st, #st.data.text, #st.data.text, v); return false end,
		INSERT = function(e, st, v) replace(e, st, st.data.caret, st.data.caret, v); return false end,
		DELETERANGE = function(e, st, v)
			local a, b = tostring(v or ""):match("^(%d+)%s*[,;:]%s*(%d+)$")
			if a then replace(e, st, tonumber(a), tonumber(b), "") end
			return false
		end,
		CARETPOS = function(e, st, v) st.data.caret = clamp(st, tonumber(v) or 0); st.data.anchor = st.data.caret; return false end,
		SELECTIONPOS = function(e, st, v)
			local a, b = tostring(v or ""):match("^(%d+)%s*[,;:]%s*(%d+)$")
			if a then st.data.anchor, st.data.caret = clamp(st, tonumber(a)), clamp(st, tonumber(b)) end
			return false
		end,
		SCROLLTOPOS = function(e, st, v) st.data.scroll_y = tonumber(v) or 0; return false end,
		SCROLLTO = function(e, st, v) st.data.scroll_x = tonumber(v) or 0; return false end,
	},
	get = {
		VALUE = function(e, st) return st.data.text or "" end,
		COUNT = function(e, st) return #st.data.text end,
		CARET = function(e, st) return tostring(st.data.caret or 0) end,
		CARETPos = function() end,
		CARETPOS = function(e, st) return tostring(st.data.caret or 0) end,
		SELECTIONPOS = function(e, st) local a, b = sorted_selection(st); return a .. ":" .. b end,
		SELECTION = function(e, st) local a, b = sorted_selection(st); return a ~= b and "YES" or "NO" end,
		SELECTEDTEXT = function(e, st) local a, b = sorted_selection(st); return st.data.text:sub(a + 1, b) end,
		LINECOUNT = function(e, st) return select(2, st.data.text:gsub("\n", "\n")) + 1 end,
		LINEVALUE = function(e, st) local n = tonumber(Element.own(e, "LINE") or 1) or 1; local lines = {}; for x in (st.data.text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = x end; return lines[n] or "" end,
	},
	callbacks = { ACTION = true, VALUECHANGED_CB = true, CARET_CB = true },
}
local function create(e, st)
	st.data.text = st.data.text or tostring(Element.own(e, "VALUE") or "")
	st.data.caret, st.data.anchor = #st.data.text, #st.data.text
	st.data.captured = false
end
common.create = create
Classes.define(setmetatable({ name = "text", defaults = common.defaults }, { __index = common }))
local multi = {}
for k, v in pairs(common) do multi[k] = v end
multi.name, multi.defaults = "multiline", {}
for k, v in pairs(common.defaults) do multi.defaults[k] = v end
multi.defaults.MULTILINE, multi.defaults.WORDWRAP, multi.defaults.VISIBLELINES = "YES", "NO", "4"
Classes.define(multi)
return M
