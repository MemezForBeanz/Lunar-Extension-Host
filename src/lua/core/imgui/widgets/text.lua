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
-- Win32 EDIT geometry --------------------------------------------------------------------
-- IUP maps BORDER=YES to WS_EX_CLIENTEDGE: the text starts 3 px inside the control on
-- both axes (the 2 px client edge and the edit's 1 px format inset; iupdrvTextAddBorders
-- adds the same 3 px per side to the natural size). PADDING is EM_SETMARGINS, horizontal
-- only (winTextSetPaddingAttrib). Measured against the IUP build with
-- scripts/ui_textmargin.lua.
local function is_multiline(e, st)
	return st.classname == "multiline" or yes(attr(e, "MULTILINE"))
end
local function frame(e, st)
	local bi = yes(attr(e, "BORDER")) and 3 or 0
	local px = pair(attr(e, "PADDING"))
	return st.x + bi + px, st.y + bi, math.max(0, st.w - 2 * (bi + px)), math.max(0, st.h - 2 * bi)
end
-- One UTF-8 character (a lead byte and its continuation bytes).
local UTF8_CHAR = "[%z\1-\127\194-\244][\128-\191]*"
local function bullet(c) return c == "\n" and "\n" or "•" end
-- The shown text of a byte range of the real text (a password bullet per character).
local function shown_sub(e, st, a, b)
	local s = (st.data.text or ""):sub(a + 1, b)
	if yes(attr(e, "PASSWORD")) then s = s:gsub(UTF8_CHAR, bullet) end
	return s
end
local function shown_text(e, st) return shown_sub(e, st, 0, #(st.data.text or "")) end
local function lines_of(s)
	local out, start = {}, 0
	while true do
		local nl = s:find("\n", start + 1, true)
		if not nl then out[#out + 1] = { start, #s }; break end
		out[#out + 1] = { start, nl - 1 }
		start = nl
	end
	return out
end
-- ES_LEFT / ES_CENTER / ES_RIGHT (winTextMapMethod from ALIGNMENT): a line narrower than
-- the format rectangle is offset inside it; a wider one starts at the left edge.
local function align_dx(e, line_w, width)
	local a = tostring(attr(e, "ALIGNMENT") or "ALEFT"):upper()
	if line_w >= width then return 0 end
	if a == "ARIGHT" then return width - line_w end
	if a == "ACENTER" then return math.floor((width - line_w) / 2) end
	return 0
end
-- EDIT_CharFromPos: the character boundary nearest to the point.
local function pos_from_point(e, st, lx, ly)
	local text = st.data.text or ""
	local font = Fonts.forElement(e)
	local _, ch = font:charsize()
	local fx, fy, fw = frame(e, st)
	fx, fy = fx - st.x, fy - st.y
	local lines = lines_of(text)
	local li = 1
	if is_multiline(e, st) then
		li = math.floor((ly - fy + (st.data.scroll_y or 0)) / math.max(1, ch)) + 1
		li = math.max(1, math.min(#lines, li))
	end
	local a, b = lines[li][1], lines[li][2]
	local line_w = font:measure(shown_sub(e, st, a, b))
	local x = lx - fx + (st.data.scroll_x or 0) - align_dx(e, line_w, fw)
	if x <= 0 then return a end
	local p, prev_w = a, 0
	while p < b do
		local c, q = utf8_char(text, p + 1)
		if not c then break end
		local w = font:measure(shown_sub(e, st, a, q - 1))
		if x < (prev_w + w) / 2 then return p end
		p, prev_w = q - 1, w
	end
	return b
end
-- EDIT_EM_ScrollCaret (single line): the caret leaving the format rectangle scrolls the
-- text so it lands a third of the width inside, and never scrolls past the text's end.
local function scroll_caret(e, st)
	if is_multiline(e, st) then return end
	local font = Fonts.forElement(e)
	local _, _, fw = frame(e, st)
	if fw <= 0 then return end
	local total = font:measure(shown_text(e, st))
	local cx = font:measure(shown_sub(e, st, 0, st.data.caret or 0))
	local sx = st.data.scroll_x or 0
	local third = math.floor(fw / 3)
	if cx - sx < 0 then sx = math.max(0, cx - third)
	elseif cx - sx > fw then sx = math.max(0, math.min(cx - (fw - third), total - fw)) end
	if total <= fw then sx = 0 end
	st.data.scroll_x = sx
end
-- The default EDIT word break procedure: words are runs of non-blank characters.
local function blank(c) return c == " " or c == "\t" or c == "\n" or c == "\r" end
local function word_at(s, p)
	local a, b = p, p
	while a > 0 and not blank(s:sub(a, a)) do a = a - 1 end
	while b < #s and not blank(s:sub(b + 1, b + 1)) do b = b + 1 end
	return a, b
end
-- EM_LINESCROLL: the first visible line, clamped so the last line can reach the bottom
-- (Wine's EDIT_EM_LineScroll: never past line_count - visible lines).
local function line_scroll_to(e, st, first)
	if not is_multiline(e, st) then return end
	local _, ch = Fonts.forElement(e):charsize()
	ch = math.max(1, ch)
	local _, _, _, fh = frame(e, st)
	local lines = #lines_of(st.data.text or "")
	local visible = math.max(1, math.floor(fh / ch))
	first = math.max(0, math.min(math.floor(first), math.max(0, lines - visible)))
	st.data.scroll_y = first * ch
	Element.hooks.invalidate(e, "paint", "SCROLL")
end
local function first_visible(e, st)
	local _, ch = Fonts.forElement(e):charsize()
	return math.floor((st.data.scroll_y or 0) / math.max(1, ch))
end
-- winTextSetScrollToAttrib: "lin,col" on a multiline (1-based, iupStrToIntInt with ','
-- so "12:1" reads as line 12), then winTextScrollTo's EM_LINESCROLL. A single-line
-- EDIT ignores EM_LINESCROLL.
local function scroll_to(e, st, v)
	if not is_multiline(e, st) then return end
	local lin = tonumber(tostring(v or ""):match("^%s*(-?%d+)")) or 1
	line_scroll_to(e, st, math.max(1, lin) - 1)
end
-- winTextSetLinColToPosition: 1-based line and column to a position, the line clamped to
-- the last one and the column to just after the line's last character.
local function rt_of() return package.loaded["core.imgui.Runtime"] end
local function lincol_to_pos(text, lin, col)
	local lines = lines_of(text or "")
	lin = math.max(1, math.min(#lines, math.floor(lin)))
	local ln = lines[lin]
	col = math.max(1, math.min(ln[2] - ln[1] + 1, math.floor(col)))
	return ln[1] + col - 1
end
-- winTextGetLinColFromPosition: a position to 1-based line and column.
local function pos_to_lincol(text, p)
	local line, col = line_at(text or "", p)
	return line + 1, col + 1
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
-- winTextCallCaretCb: lin and col start at 1 (winTextGetLinColFromPosition), and the
-- callback fires only when the position changed.
local function caret_cb(e, st)
	if st.data.last_caret_pos == st.data.caret then return end
	st.data.last_caret_pos = st.data.caret
	local line, col = line_at(st.data.text, st.data.caret)
	Element.call(e, "CARET_CB", line + 1, col + 1, st.data.caret)
end
-- After the caret moved: CARET_CB, EM_SCROLLCARET, and the blink restarts shown.
local function moved(e, st, rt)
	scroll_caret(e, st)
	if is_multiline(e, st) then
		-- EDIT_EM_ScrollCaret (multiline): scroll the fewest lines that show the caret's line
		local _, ch = Fonts.forElement(e):charsize()
		local _, _, _, fh = frame(e, st)
		local line = select(2, (st.data.text or ""):sub(1, st.data.caret or 0):gsub("\n", "\n"))
		local top, sy = line * ch, st.data.scroll_y or 0
		if top < sy then sy = top
		elseif top + ch > sy + fh then sy = math.max(0, top + ch - fh) end
		st.data.scroll_y = sy
	end
	st.data.caret_moved = rt and rt.now and rt.now() or nil
	caret_cb(e, st)
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
	local _, ch = font:charsize()
	local bw = yes(attr(e, "BORDER")) and (tonumber(attr(e, "BORDERWIDTH")) or 1) or 0
	local fx, fy, fw, fh = frame(e, st)
	local bg = attr(e, "BGCOLOR")
	if bg then dc:fill(st.x, st.y, st.w, st.h, bg, { radius = tonumber(attr(e, "CORNERRADIUS")) or 0 }) end
	local focused = rt and rt.focused and rt.focused() == e
	local value = st.data.text
	local sx, sy = st.data.scroll_x or 0, st.data.scroll_y or 0
	dc:clip_push(st.x + bw, st.y + bw, math.max(0, st.w - bw * 2), math.max(0, st.h - bw * 2))
	if value == "" and attr(e, "CUEBANNER") then
		-- EM_SETCUEBANNER: the cue shows until text is typed (fDrawFocused = TRUE in IUP)
		local cue = attr(e, "CUEBANNER")
		dc:text(cue, fx + align_dx(e, font:measure(cue), fw), fy, fw, ch,
			attr(e, "PLACEHOLDERCOLOR") or attr(e, "FGCOLOR"), font, { clip = true })
	elseif value ~= "" and yes(attr(e, "WORDWRAP")) and is_multiline(e, st) then
		dc:text(shown_text(e, st), fx - sx, fy - sy, fw, math.max(ch, fh), attr(e, "FGCOLOR"), font,
			{ clip = true, wrap = fw })
	elseif value ~= "" then
		local a, b = sorted_selection(st)
		local selcolor = attr(e, "SELECTIONCOLOR") or "100 140 220 100"
		local y = fy - sy
		for _, ln in ipairs(lines_of(value)) do
			if y + ch >= st.y and y <= st.y + st.h then
				local s = shown_sub(e, st, ln[1], ln[2])
				local x = fx - sx + align_dx(e, font:measure(s), fw)
				dc:text(s, x, y, math.max(fw, font:measure(s)), ch, attr(e, "FGCOLOR"), font, { clip = true })
				local la, lb = math.max(a, ln[1]), math.min(b, ln[2])
				if la < lb then
					local x1 = x + font:measure(shown_sub(e, st, ln[1], la))
					local x2 = x + font:measure(shown_sub(e, st, ln[1], lb))
					dc:fill(x1, y, math.max(1, x2 - x1), ch, selcolor)
				end
			end
			y = y + ch
		end
	end
	if focused and not yes(attr(e, "READONLY")) then
		-- the system caret blinks every GetCaretBlinkTime() ms (530 by default)
		local now = rt.now and rt.now() or 0
		local since = now - (st.data.caret_moved or now)
		local phase = math.floor(since / 0.53)
		if phase % 2 == 0 then
			local lines = lines_of(value)
			local li = 1
			for i, ln in ipairs(lines) do if st.data.caret >= ln[1] and st.data.caret <= ln[2] then li = i; break end end
			local ln = lines[li]
			local s = shown_sub(e, st, ln[1], ln[2])
			local cx = fx - sx + align_dx(e, font:measure(s), fw) + font:measure(shown_sub(e, st, ln[1], st.data.caret))
			local cy = fy - sy + (li - 1) * ch
			dc:line(cx, cy, cx, cy + ch, attr(e, "CARETCOLOR") or attr(e, "FGCOLOR"), 1)
		end
		if rt.wakeAt then rt.wakeAt((st.data.caret_moved or now) + (phase + 1) * 0.53)
		elseif rt.animate then rt.animate() end
	end
	dc:clip_pop()
	if bw > 0 then dc:rect(st.x, st.y, st.w, st.h, focused and (attr(e, "FOCUSCOLOR") or attr(e, "BORDERCOLOR")) or attr(e, "BORDERCOLOR"), { thickness = bw }) end
end
local function event(e, st, ev, rt)
	local text = st.data.text
	if ev.type == "focus" or ev.type == "blur" then
		if rt and rt.redraw then rt.redraw(e) end
		return true
	elseif ev.type == "press" then
		if ev.button and ev.button ~= 1 then return false end
		local p = pos_from_point(e, st, ev.lx or ev.x or 0, ev.ly or ev.y or 0)
		if ev.double then
			local a, b = word_at(text, p)
			st.data.anchor, st.data.caret = a, b
		else
			st.data.caret = p; st.data.anchor = ev.mods and ev.mods.shift and st.data.anchor or p
		end
		st.data.captured = true
		if rt and rt.capture then rt.capture(e) end
		moved(e, st, rt); return true
	elseif ev.type == "move" and st.data.captured then
		st.data.caret = pos_from_point(e, st, ev.lx or ev.x or 0, ev.ly or ev.y or 0)
		moved(e, st, rt); return true
	elseif ev.type == "wheel" and is_multiline(e, st) and st.data.flat_host and Element.state(st.data.flat_host) then
		-- Lunar fork WM_MOUSEWHEEL: POSY -= (delta / WHEEL_DELTA) * 3 * liney on the host
		local host = st.data.flat_host
		local liney = st.data.flat_liney or 1
		local posy = tonumber(Element.getAttribute(host, "POSY")) or 0
		Element.setAttribute(host, "POSY", tostring(posy - (tonumber(ev.dy) or 0) * 3 * liney))
		return true
	elseif ev.type == "wheel" and is_multiline(e, st) then
		-- WM_MOUSEWHEEL: SPI_GETWHEELSCROLLLINES (3) lines a notch
		local _, ch = Fonts.forElement(e):charsize()
		local lines = #lines_of(text)
		local _, _, _, fh = frame(e, st)
		local max_y = math.max(0, lines * ch - fh)
		local dy = tonumber(ev.dy) or 0
		st.data.scroll_y = math.max(0, math.min(max_y, (st.data.scroll_y or 0) - dy * 3 * ch))
		if rt and rt.redraw then rt.redraw(e) end
		return max_y > 0
	elseif ev.type == "release" then
		st.data.captured = false
		if rt and rt.release then rt.release() end
		return true
	elseif ev.type == "char" then
		local a, b = sorted_selection(st)
		replace(e, st, a, b, ev.char, rt); moved(e, st, rt); return true
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
		elseif (base == iup.K_UP or base == iup.K_DOWN) and is_multiline(e, st) then
			local font = Fonts.forElement(e)
			local _, ch = font:charsize()
			local lines = lines_of(text)
			local li = 1
			for i, ln in ipairs(lines) do if st.data.caret >= ln[1] and st.data.caret <= ln[2] then li = i; break end end
			local ln = lines[li]
			local fx, fy = frame(e, st)
			local cx = font:measure(shown_sub(e, st, ln[1], st.data.caret)) - (st.data.scroll_x or 0) + (fx - st.x)
			local target = li + (base == iup.K_UP and -1 or 1)
			if target >= 1 and target <= #lines then
				st.data.caret = pos_from_point(e, st, cx, (fy - st.y) + (target - 1) * ch - (st.data.scroll_y or 0) + 1)
			end
		elseif base == iup.K_HOME and ctrl then st.data.caret = 0
		elseif base == iup.K_END and ctrl then st.data.caret = #text
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
		moved(e, st, rt); if rt and rt.redraw then rt.redraw(e) end
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
		-- winTextSetScrollToPosAttrib: the position's line, as SCROLLTO
		SCROLLTOPOS = function(e, st, v)
			local p = clamp(st, tonumber(v) or 0)
			local line = select(2, (st.data.text or ""):sub(1, p):gsub("\n", "\n"))
			line_scroll_to(e, st, line)
			return false
		end,
		SCROLLTO = function(e, st, v) scroll_to(e, st, v); return false end,
		-- Lunar fork (patch 0001, iupwin_text.c): 1-based first visible line of a multiline
		-- winTextSetCaretAttrib: "lin,col" on a multiline (iupStrToIntInt with ',', so "12:1"
		-- is line 12), the column on a single line, then EM_SCROLLCARET
		CARET = function(e, st, v)
			local text = st.data.text or ""
			local p
			if is_multiline(e, st) then
				local lin, col = tostring(v or ""):match("^%s*(-?%d+)%s*,%s*(-?%d+)")
				lin = tonumber(lin) or tonumber(tostring(v or ""):match("^%s*(-?%d+)")) or 1
				p = lincol_to_pos(text, lin, tonumber(col) or 1)
			else
				p = clamp(st, (tonumber(tostring(v or ""):match("^%s*(-?%d+)")) or 1) - 1)
			end
			st.data.caret, st.data.anchor = p, p
			st.data.last_caret_pos = p -- a programmatic move fires no CARET_CB
			moved(e, st, rt_of(e))
			return false
		end,
		-- winTextSetSelectionAttrib: NONE, ALL, "l1,c1:l2,c2" (multiline) or "c1:c2", 1-based;
		-- the anchor is the start and the caret the end (EM_SETSEL)
		SELECTION = function(e, st, v)
			local s = tostring(v or "NONE"):upper()
			local text = st.data.text or ""
			if v == nil or s == "NONE" then st.data.anchor = st.data.caret; return false end
			if s == "ALL" then st.data.anchor, st.data.caret = 0, #text; return false end
			if is_multiline(e, st) then
				local l1, c1, l2, c2 = s:match("^%s*(%d+)%s*,%s*(%d+)%s*:%s*(%d+)%s*,%s*(%d+)")
				if not l1 then return false end
				l1, c1, l2, c2 = tonumber(l1), tonumber(c1), tonumber(l2), tonumber(c2)
				if l1 < 1 or c1 < 1 or l2 < 1 or c2 < 1 then return false end
				st.data.anchor, st.data.caret = lincol_to_pos(text, l1, c1), lincol_to_pos(text, l2, c2)
			else
				local a, b = s:match("^%s*(%d+)%s*:%s*(%d+)")
				if not a or tonumber(a) < 1 or tonumber(b) < 1 then return false end
				st.data.anchor, st.data.caret = clamp(st, tonumber(a) - 1), clamp(st, tonumber(b) - 1)
			end
			return false
		end,
		FIRSTVISIBLELINE = function(e, st, v)
			local line = tonumber(v)
			if line then line_scroll_to(e, st, math.max(1, line) - 1) end
			return false
		end,
	},
	get = {
		VALUE = function(e, st) return st.data.text or "" end,
		COUNT = function(e, st) return #st.data.text end,
		-- winTextGetCaretAttrib: "lin,col" on a multiline, the column on a single line (1-based)
		CARET = function(e, st)
			local lin, col = pos_to_lincol(st.data.text, st.data.caret or 0)
			if is_multiline(e, st) then return lin .. "," .. col end
			return tostring(col)
		end,
		CARETPos = function() end,
		CARETPOS = function(e, st) return tostring(st.data.caret or 0) end,
		SELECTIONPOS = function(e, st) local a, b = sorted_selection(st); return a .. ":" .. b end,
		-- winTextGetSelectionAttrib: nothing when empty, else 1-based "l1,c1:l2,c2" or "a:b"
		SELECTION = function(e, st)
			local a, b = sorted_selection(st)
			if a == b then return nil end
			if is_multiline(e, st) then
				local l1, c1 = pos_to_lincol(st.data.text, a)
				local l2, c2 = pos_to_lincol(st.data.text, b)
				return string.format("%d,%d:%d,%d", l1, c1, l2, c2)
			end
			return (a + 1) .. ":" .. (b + 1)
		end,
		SELECTEDTEXT = function(e, st) local a, b = sorted_selection(st); return st.data.text:sub(a + 1, b) end,
		LINECOUNT = function(e, st) return select(2, st.data.text:gsub("\n", "\n")) + 1 end,
		FIRSTVISIBLELINE = function(e, st)
			if not is_multiline(e, st) then return "1" end
			return tostring(first_visible(e, st) + 1)
		end,
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
