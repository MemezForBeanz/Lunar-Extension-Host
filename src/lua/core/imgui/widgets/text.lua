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
	if M.isMulti and M.isMulti(e, st) then
		-- SetWindowText: the EDIT starts over at the top with the caret at 0 (measured)
		st.data.caret, st.data.anchor, st.data.top_line, st.data.scroll_x = 0, 0, 0, 0
	else
		st.data.caret, st.data.anchor = #st.data.text, #st.data.text
	end
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
-- The multiline EDIT (iupwin_text.c maps a multiline to an EDIT with ES_MULTILINE,
-- ES_AUTOVSCROLL, ES_AUTOHSCROLL unless WORDWRAP, and WS_VSCROLL/WS_HSCROLL from SCROLLBAR).
-- What the EDIT does was measured on the IUP build (scripts/ui_scroll.lua): the format rect
-- is the client less 1 px each side (EM_GETRECT 1,1,w-1,...) cut to whole lines; a line is
-- tmHeight; the vertical bar ranges over the lines with the visible lines as its page, the
-- horizontal one over the widest line with the format width as its page; both stay shown,
-- disabled, while nothing scrolls; the wheel scrolls 3 lines a notch (SPI_GETWHEELSCROLLLINES),
-- an arrow 1, the track a page less one line; EM_SCROLLCARET brings the caret's line into
-- view at the top or bottom edge.
local Win = require("core.imgui.widgets.winscrollbar")
local WHEEL_LINES = 3 -- SPI_GETWHEELSCROLLLINES default
local HSCROLL_FRACTION = 3 -- the EDIT jumps a third of the width when the caret leaves the view

local function is_multi(e, st) return st.classname == "multiline" or yes(attr(e, "MULTILINE")) end
M.isMulti = is_multi

--- The text as lines: { s = offset of the first byte (0-based), t = text }. Appending keeps
-- the lines already split (a growing log is not split again).
local function lines_of(st)
	local text = st.data.text
	local cache = st.data.lines
	if cache and st.data.lines_src == text then return cache end
	local out, from = {}, 0
	local old = st.data.lines_src
	if cache and old and #old > 0 and #text > #old and text:sub(1, #old) == old then
		-- keep every line but the last one (which may have grown)
		for i = 1, #cache - 1 do out[i] = cache[i] end
		from = cache[#cache].s
		st.data.text_w_upto = math.min(st.data.text_w_upto or 0, #cache - 1)
	else
		st.data.text_w, st.data.text_w_upto = 0, 0
	end
	local pos = from
	local p = from + 1
	while true do
		local nl = text:find("\n", p, true)
		if not nl then out[#out + 1] = { s = pos, t = text:sub(p) }; break end
		out[#out + 1] = { s = pos, t = text:sub(p, nl - 1) }
		pos = nl
		p = nl + 1
	end
	st.data.lines, st.data.lines_src = out, text
	return out
end
M.lines = lines_of

local function line_of(lines, p)
	local lo, hi = 1, #lines
	while lo < hi do
		local mid = math.floor((lo + hi + 1) / 2)
		if lines[mid].s <= p then lo = mid else hi = mid - 1 end
	end
	return lo
end

--- The widest line in pixels (the horizontal range), measured once per line.
local function text_width(e, st, font)
	local lines = lines_of(st)
	local w = st.data.text_w or 0
	for i = (st.data.text_w_upto or 0) + 1, #lines do
		local lw = font:measure(lines[i].t)
		if lw > w then w = lw end
	end
	st.data.text_w, st.data.text_w_upto = w, #lines
	return w
end

--- Client rect, format rect and line metrics (dialog coordinates), plus which bars exist.
local function metrics(e, st)
	local font = Fonts.forElement(e)
	local cw, lh = font:charsize()
	local border = yes(attr(e, "BORDER")) and 2 or 0 -- WS_EX_CLIENTEDGE
	local sb = tostring(attr(e, "SCROLLBAR") or "YES"):upper()
	local sbv = sb == "YES" or sb == "VERTICAL"
	-- winTextMapMethod: WORDWRAP removes the horizontal bar
	local sbh = (sb == "YES" or sb == "HORIZONTAL") and not yes(attr(e, "WORDWRAP"))
	local cx, cy = st.x + border, st.y + border
	local cwid, chei = st.w - 2 * border, st.h - 2 * border
	if sbv then cwid = cwid - Win.SIZE end
	if sbh then chei = chei - Win.SIZE end
	local pad = pair(attr(e, "PADDING")) -- EM_SETMARGINS, horizontal only
	local vlc = math.max(0, math.floor((chei - 2) / math.max(1, lh)))
	local m = {
		font = font, cw = cw, lh = lh, border = border, sbh = sbh, sbv = sbv,
		cx = cx, cy = cy, cwid = math.max(0, cwid), chei = math.max(0, chei),
		fx = cx + 1 + pad, fy = cy + 1, fw = math.max(0, cwid - 2 - 2 * pad), fh = vlc * lh, vlc = vlc,
	}
	-- for scripts/ui_scroll.lua: the format rect in client coordinates, as EM_GETRECT
	st.data.metrics = { x = 1 + pad, y = 1, w = m.fw, h = m.fh, lh = lh }
	return m
end

local function max_top(st, m) return math.max(0, #lines_of(st) - math.max(1, m.vlc)) end

local function clamp_view(e, st, m)
	st.data.top_line = math.max(0, math.min(max_top(st, m), st.data.top_line or 0))
	local tw = text_width(e, st, m.font)
	st.data.scroll_x = math.max(0, math.min(math.max(0, tw - m.fw), st.data.scroll_x or 0))
end

--- EM_SCROLLCARET (EDIT_EM_ScrollCaret): the caret's line to the nearest edge, and a third
-- of the width past the caret when it left the view sideways.
local function scroll_to(e, st, p)
	if not is_multi(e, st) then return end
	local m = metrics(e, st)
	local lines = lines_of(st)
	local li = line_of(lines, p) - 1
	local vlc = math.max(1, m.vlc)
	local top = st.data.top_line or 0
	if li < top then top = li elseif li >= top + vlc then top = li - vlc + 1 end
	st.data.top_line = top
	local line = lines[li + 1]
	local x = m.font:measure(line.t:sub(1, p - line.s))
	local sx = st.data.scroll_x or 0
	if x < sx then sx = x - math.floor(m.fw / HSCROLL_FRACTION)
	elseif x > sx + m.fw then sx = x - math.floor((HSCROLL_FRACTION - 1) * m.fw / HSCROLL_FRACTION) end
	st.data.scroll_x = sx
	clamp_view(e, st, m)
	Element.hooks.invalidate(e, "paint", "POS")
end
function M.scrollCaret(e, st) scroll_to(e, st, st.data.caret or 0) end
M.scrollTo = scroll_to

local text_owner = {
	range = function(e, vertical)
		local st = Element.state(e)
		local m = metrics(e, st)
		if vertical then return #lines_of(st), math.max(1, m.vlc), st.data.top_line or 0 end
		return text_width(e, st, m.font), m.fw, st.data.scroll_x or 0
	end,
	-- EDIT_WM_VScroll / HScroll: a line, or a page less one line (vertical); a character
	-- width, or the format width (horizontal: not measured)
	step = function(e, vertical, part, pos, page)
		local st = Element.state(e)
		if vertical then
			local pg = math.max(1, page - 1)
			if part == "linedown" then return pos + 1 elseif part == "lineup" then return pos - 1
			elseif part == "pagedown" then return pos + pg elseif part == "pageup" then return pos - pg end
		else
			local cw = metrics(e, st).cw
			if part == "linedown" then return pos + cw elseif part == "lineup" then return pos - cw
			elseif part == "pagedown" then return pos + page elseif part == "pageup" then return pos - page end
		end
	end,
	scroll = function(e, vertical, pos)
		local st = Element.state(e)
		if vertical then st.data.top_line = math.floor(pos + 0.5) else st.data.scroll_x = math.floor(pos + 0.5) end
		clamp_view(e, st, metrics(e, st))
		Element.hooks.invalidate(e, "paint", "POS")
	end,
}

--- The bars of this frame (shown while SCROLLBAR asks for them; no thumb when disabled).
local function ml_bars(e, st, m)
	local lines = lines_of(st)
	local tw = text_width(e, st, m.font)
	Win.set(e,
		m.sbv and { x = m.cx + m.cwid, y = m.cy, w = Win.SIZE, h = m.chei, max = #lines, page = math.max(1, m.vlc), pos = st.data.top_line or 0 } or nil,
		m.sbh and { x = m.cx, y = m.cy + m.chei, w = m.cwid, h = Win.SIZE, max = tw, page = m.fw, pos = st.data.scroll_x or 0 } or nil)
end

--- The character offset at dialog point (x, y): the line under it, the nearest boundary.
local function offset_at(e, st, m, x, y)
	local lines = lines_of(st)
	local li = (st.data.top_line or 0) + math.floor((y - m.fy) / math.max(1, m.lh))
	li = math.max(0, math.min(#lines - 1, li))
	local line = lines[li + 1]
	local px = x - m.fx + (st.data.scroll_x or 0)
	if px <= 0 then return line.s end
	local t, best, prev_w, i = line.t, #line.t, 0, 1
	while i <= #t do
		local _, nxt = utf8_char(t, i)
		local w = m.font:measure(t:sub(1, nxt - 1))
		if px < (prev_w + w) / 2 then best = i - 1; break end
		prev_w, i = w, nxt
	end
	return line.s + best
end

local function ml_draw(e, st, dc, rt)
	local m = metrics(e, st)
	clamp_view(e, st, m)
	local bg = attr(e, "BGCOLOR")
	if bg then dc:fill(st.x, st.y, st.w, st.h, bg) end
	local focused = rt and rt.focused and rt.focused() == e
	local lines = lines_of(st)
	local fg = attr(e, "FGCOLOR")
	local value = st.data.text
	local password = yes(attr(e, "PASSWORD"))
	dc:clip_push(m.cx, m.cy, m.cwid, m.chei)
	if value == "" and attr(e, "CUEBANNER") and not focused then
		dc:text(attr(e, "CUEBANNER"), m.fx, m.fy, m.fw, m.lh, attr(e, "PLACEHOLDERCOLOR") or fg, m.font, { clip = true })
	end
	local a, b = sorted_selection(st)
	local top = st.data.top_line or 0
	local x0 = m.fx - (st.data.scroll_x or 0)
	-- the partly visible line under the last full one is drawn too, clipped by the client
	local last = math.min(#lines, top + math.max(1, m.vlc) + 1)
	for li = top + 1, last do
		local line = lines[li]
		local y = m.fy + (li - 1 - top) * m.lh
		local t = password and line.t:gsub("[%z\1-\127\194-\244][\128-\191]*", "*") or line.t
		local ls, le = line.s, line.s + #line.t
		if a ~= b and b > ls and a <= le then
			local sa, sb = math.max(a, ls) - ls, math.min(b, le) - ls
			local sx = x0 + m.font:measure(line.t:sub(1, sa))
			local sw = m.font:measure(line.t:sub(sa + 1, sb))
			if b > le then sw = sw + m.cw end -- the selected line break
			dc:fill(sx, y, math.max(1, sw), m.lh, attr(e, "SELECTIONCOLOR") or "100 140 220 100")
		end
		if t ~= "" then dc:text(t, x0, y, math.max(0, m.font:measure(t) + 1), m.lh, fg, m.font, { clip = true }) end
	end
	if focused then
		local li = line_of(lines, st.data.caret or 0)
		if li - 1 >= top and li - 1 < top + math.max(1, m.vlc) + 1 then
			local line = lines[li]
			local cx = x0 + m.font:measure(line.t:sub(1, (st.data.caret or 0) - line.s))
			local y = m.fy + (li - 1 - top) * m.lh
			dc:line(cx, y, cx, y + m.lh, attr(e, "CARETCOLOR") or fg, 1)
		end
		if rt and rt.animate then rt.animate() end
	end
	dc:clip_pop()
	ml_bars(e, st, m)
	Win.tick(e, text_owner, rt)
	Win.draw(e, st, dc)
	if m.border > 0 then
		dc:rect(st.x, st.y, st.w, st.h, focused and (attr(e, "FOCUSCOLOR") or attr(e, "BORDERCOLOR")) or attr(e, "BORDERCOLOR"), { thickness = 1 })
	end
end

--- Moves of the caret a multiline adds: Up/Down keep the column's x, PgUp/PgDn a page,
-- Ctrl+Home/End the ends of the text, Home/End the line's.
local function ml_move(e, st, base, ctrl)
	local m = metrics(e, st)
	local lines = lines_of(st)
	local caret = st.data.caret or 0
	local li = line_of(lines, caret)
	local line = lines[li]
	local goal = st.data.goal_x or m.font:measure(line.t:sub(1, caret - line.s))
	local function to_line(n)
		n = math.max(1, math.min(#lines, n))
		local l = lines[n]
		local p = offset_at(e, st, m, m.fx - (st.data.scroll_x or 0) + goal, m.fy + (n - 1 - (st.data.top_line or 0)) * m.lh)
		return math.max(l.s, math.min(l.s + #l.t, p)), true
	end
	if base == iup.K_UP then return to_line(li - 1)
	elseif base == iup.K_DOWN then return to_line(li + 1)
	elseif base == iup.K_PGUP then st.data.top_line = (st.data.top_line or 0) - math.max(1, m.vlc); return to_line(li - math.max(1, m.vlc))
	elseif base == iup.K_PGDN then st.data.top_line = (st.data.top_line or 0) + math.max(1, m.vlc); return to_line(li + math.max(1, m.vlc))
	elseif base == iup.K_HOME then return ctrl and 0 or line.s
	elseif base == iup.K_END then return ctrl and #st.data.text or line.s + #line.t
	end
	return nil
end

local function ml_event(e, st, ev, rt, single_event)
	local t = ev.type
	if t == "wheel" then
		-- EDIT WM_MOUSEWHEEL: SPI_GETWHEELSCROLLLINES lines per notch, the rest kept for the
		-- next one; the EDIT keeps the wheel
		if ev.mods and (ev.mods.ctrl or ev.mods.shift) then return false end
		local m = metrics(e, st)
		local lines = math.min(#lines_of(st), WHEEL_LINES)
		local delta = (ev.dy or 0) * 120
		local rem = st.data.wheel_rem or 0
		if rem ~= 0 and (rem > 0) ~= (delta > 0) then rem = 0 end
		delta = delta + rem
		local n = lines * delta / 120
		n = n >= 0 and math.floor(n) or -math.floor(-n)
		st.data.wheel_rem = delta - n * 120 / math.max(1, lines)
		st.data.top_line = (st.data.top_line or 0) - n
		clamp_view(e, st, m)
		Element.hooks.invalidate(e, "paint", "POS")
		return true
	end
	if t == "press" and ev.button == 1 and Win.press(e, text_owner, ev.x, ev.y, rt) then return true end
	if t == "move" and Win.move(e, text_owner, ev.x, ev.y, rt) then return true end
	if t == "release" and ev.button == 1 and Win.release(e, text_owner, ev.x, ev.y, rt) then return true end
	if t == "leave" then Win.leave(e, rt); return true end
	if t == "press" or (t == "move" and st.data.captured) then
		local m = metrics(e, st)
		local p = offset_at(e, st, m, ev.x, ev.y)
		st.data.caret = p
		if t == "press" then st.data.anchor = ev.mods and ev.mods.shift and st.data.anchor or p; st.data.captured = true
			if rt and rt.capture then rt.capture(e) end
		end
		st.data.goal_x = nil
		scroll_to(e, st, p)
		caret_cb(e, st)
		return true
	end
	if t == "key" then
		local k = ev.key
		local ctrl = (ev.mods and ev.mods.ctrl) or iup.isCtrlXkey(k)
		local shift = (ev.mods and ev.mods.shift) or iup.isShiftXkey(k)
		local base = iup.XkeyBase(k)
		if base == iup.K_CR and not ctrl then
			-- ES_WANTRETURN: Enter is a line break (Ctrl+Enter is the dialog's DEFAULTENTER)
			local a, b = sorted_selection(st)
			replace(e, st, a, b, "\n", rt); st.data.goal_x = nil; scroll_to(e, st, st.data.caret); caret_cb(e, st)
			return true
		elseif base == iup.K_TAB and not ctrl then
			-- iupKeyProcessNavigation: Tab is a character in a multiline, Ctrl+Tab moves on
			local a, b = sorted_selection(st)
			replace(e, st, a, b, "\t", rt); scroll_to(e, st, st.data.caret); caret_cb(e, st)
			return true
		elseif base == iup.K_TAB and ctrl then
			if rt and rt.nextField then rt.nextField(e, shift and -1 or 1) end
			return true
		elseif base == iup.K_CR and ctrl then
			if rt and rt.activateDefault then rt.activateDefault(e, "DEFAULTENTER") end
			return true
		end
		local p = ml_move(e, st, base, ctrl)
		if p then
			local keep_goal = base == iup.K_UP or base == iup.K_DOWN or base == iup.K_PGUP or base == iup.K_PGDN
			if keep_goal and not st.data.goal_x then
				local lines = lines_of(st)
				local line = lines[line_of(lines, st.data.caret or 0)]
				st.data.goal_x = metrics(e, st).font:measure(line.t:sub(1, (st.data.caret or 0) - line.s))
			elseif not keep_goal then st.data.goal_x = nil end
			st.data.caret = p
			if not shift then st.data.anchor = p end
			scroll_to(e, st, p)
			caret_cb(e, st)
			if rt and rt.redraw then rt.redraw(e) end
			return true
		end
		local r = single_event(e, st, ev, rt)
		st.data.goal_x = nil
		scroll_to(e, st, st.data.caret or 0)
		return r
	end
	local r = single_event(e, st, ev, rt)
	if t == "char" then st.data.goal_x = nil; scroll_to(e, st, st.data.caret or 0) end
	return r
end

local function draw_any(e, st, dc, rt)
	if is_multi(e, st) then return ml_draw(e, st, dc, rt) end
	return draw(e, st, dc, rt)
end
local function event_any(e, st, ev, rt)
	if is_multi(e, st) then return ml_event(e, st, ev, rt, event) end
	return event(e, st, ev, rt)
end

local common = {
	children = 0, focusable = true, natural = text_natural, draw = draw_any, event = event_any,
	-- IUP registers BORDER, PADDING ("0x0"), VISIBLECOLUMNS ("5"), VISIBLELINES and the TXT colours (attrs.lua)
	defaults = { CURSOR = "IBEAM" },
	set = {
		VALUE = set_value,
		-- winTextSetAppendAttrib: EM_REPLACESEL at the end (it ignores ES_READONLY), after a
		-- line break when the multiline has text and APPENDNEWLINE (default YES), with the
		-- callbacks disabled; the caret ends after it.
		APPEND = function(e, st, v)
			local ins = tostring(v or "")
			local multiline = st.classname == "multiline" or yes(attr(e, "MULTILINE"))
			if multiline and #st.data.text > 0 and attr(e, "APPENDNEWLINE") ~= "NO" then ins = "\n" .. ins end
			st.data.text = st.data.text .. ins
			st.data.caret, st.data.anchor = #st.data.text, #st.data.text
			if M.scrollCaret then M.scrollCaret(e, st) end
			Element.hooks.invalidate(e, "paint", "VALUE")
			return false
		end,
		-- winTextSetInsertAttrib: EM_REPLACESEL over the selection, callbacks disabled
		INSERT = function(e, st, v)
			local a, b = sorted_selection(st)
			local ins = tostring(v or "")
			st.data.text = st.data.text:sub(1, a) .. ins .. st.data.text:sub(b + 1)
			st.data.caret, st.data.anchor = a + #ins, a + #ins
			if M.scrollCaret then M.scrollCaret(e, st) end
			Element.hooks.invalidate(e, "paint", "VALUE")
			return false
		end,
		DELETERANGE = function(e, st, v)
			local a, b = tostring(v or ""):match("^(%d+)%s*[,;:]%s*(%d+)$")
			if a then replace(e, st, tonumber(a), tonumber(b), "") end
			return false
		end,
		-- winTextSetCaretPosAttrib: EM_SETSEL, then EM_SCROLLCARET
		CARETPOS = function(e, st, v) st.data.caret = clamp(st, tonumber(v) or 0); st.data.anchor = st.data.caret; M.scrollCaret(e, st); return false end,
		SELECTIONPOS = function(e, st, v)
			local a, b = tostring(v or ""):match("^(%d+)%s*[,;:]%s*(%d+)$")
			if a then st.data.anchor, st.data.caret = clamp(st, tonumber(a)), clamp(st, tonumber(b)) end
			return false
		end,
		-- winTextSetScrollToPosAttrib / SetScrollToAttrib: bring a position (or "lin,col", from
		-- 1) into view
		SCROLLTOPOS = function(e, st, v)
			if M.isMulti(e, st) then M.scrollTo(e, st, clamp(st, tonumber(v) or 0)) else st.data.scroll_y = tonumber(v) or 0 end
			return false
		end,
		SCROLLTO = function(e, st, v)
			local lin, col = tostring(v or ""):match("^%s*(%d+)%s*[,:]%s*(%d+)")
			if lin and M.isMulti(e, st) then
				local lines = M.lines(st)
				local l = lines[math.max(1, math.min(#lines, tonumber(lin)))]
				M.scrollTo(e, st, l.s + math.min(#l.t, math.max(0, tonumber(col) - 1)))
			else st.data.scroll_x = tonumber(v) or 0 end
			return false
		end,
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
	if is_multi(e, st) then st.data.caret, st.data.anchor = 0, 0 end
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
