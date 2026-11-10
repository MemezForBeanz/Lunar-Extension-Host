--- Port of Lunar's IupFlatGrid (iup-fork patch 0022, src/iup_flatgrid.c): a virtual cell grid.
-- Only the cells in view are queried and painted. Cells sit on lanes across the scroll
-- direction and lines along it, so a vertical grid and a horizontal shelf are the same
-- arithmetic. The pixels of an image stay with the provider.
--
-- C function -> Lua (same names unless noted):
--   grid_ticks                 Runtime clock (rt.now)
--   grid_max / grid_min        U.max / U.min
--   grid_value                 grid_value
--   grid_aspect                grid_aspect
--   grid_measure               grid_measure
--   grid_lines / grid_total / grid_extent / grid_scroll / grid_set_scroll   same
--   grid_cell_xy / grid_hit / grid_first / grid_refresh                     same
--   grid_build_corners / grid_draw_corners   DC:bits with a corner radius (ImGui rounds the
--                                            image with the same antialiased arc the tiles drew)
--   grid_is_marked / grid_draw_cell / grid_redraw                           same (redraw = draw)
--   grid_touch                 rt.redraw (the whole control repaints each frame)
--   grid_mark_all / grid_mark / grid_alloc_marks / grid_reveal / grid_go / grid_activate  same
--   grid_title_matches / grid_type_ahead / grid_key / grid_button           same
--   grid_set_hover / grid_motion / grid_leave / grid_focus / grid_rehover   same
--   grid_wheel / grid_scrolled / grid_resize                                same
--   grid_set_count ... grid_set_scrollbar   class `set` / `get` entries (attribute table below)
--   grid_size                  natural
--   grid_child_size / grid_child_pos   FlatScrollbar.sync
--   grid_destroy / grid_create         destroy / create
--   iupFlatGridNewClass        Classes.define at the end
-- @module core.imgui.widgets.flatgrid
local Classes = require("core.imgui.Classes")
local Element = require("core.imgui.Element")
local iup = require("core.imgui.iup")
local FlatDraw = require("core.imgui.widgets.flatdraw")
local FlatScrollbar = require("core.imgui.widgets.flatscrollbar")
local U = require("core.imgui.widgets.rawutil")

local M = {}

local GRID_RING = 6            -- room around a cell for its selection and focus rings
local GRID_TYPEAHEAD_MS = 900
local GRID_TYPEAHEAD_MAX = 63

local GRID_PLAIN, GRID_EXTEND, GRID_TOGGLE = 0, 1, 2

local idiv, imod, max, min, atoi = U.idiv, U.imod, U.max, U.min, U.atoi
local function init_data(d)
	d._init = true
	d.count, d.cursor, d.anchor, d.hover, d.focused = 0, 0, 0, 0, false
	d.lanes, d.pitch = 1, 1
	d.marked, d.typed, d.typed_at = 0, "", 0
	d.padding, d.gutter, d.cellw, d.cellh, d.imageh, d.charh, d.available = 16, 16, 150, 0, 0, 0, 0
end
-- ih->data: the class data, made on first use (IUP runs Create before any attribute)
local function D(ih)
	local d = Element.state(ih).data
	if not d._init then init_data(d) end
	return d
end

local function grid_ticks()
	local Runtime = package.loaded["core.imgui.Runtime"]
	local now = Runtime and Runtime.now and Runtime.now() or os.clock()
	return math.floor(now * 1000)
end

local function grid_value(ih, field, pos) return U.value(ih, "CELLVALUE_CB", pos, field) end

-- ---- geometry ------------------------------------------------------------------------

local function grid_aspect(ih)
	local value = U.attr(ih, "ASPECT")
	if value then
		local a, b = tostring(value):match("^%s*([%d%.]+)%s*:%s*([%d%.]+)")
		a, b = tonumber(a), tonumber(b)
		if a and b and a > 0 and b > 0 then return a / b end
		a = tonumber(tostring(value):match("^%s*([%d%.]+)"))
		if a and a > 0 then return a end
	end
	return 2.0 / 3.0
end

local function grid_measure(ih)
	local d, st = D(ih), Element.state(ih)
	local bar = U.int(ih, "SCROLLBARSIZE")
	local _, charh = U.charsize(ih)
	d.charh = charh
	d.horizontal = U.eqnc(U.attr(ih, "ORIENTATION"), "HORIZONTAL")
	d.padding = max(U.int(ih, "PADDING"), GRID_RING)
	d.gutter = max(U.int(ih, "GUTTER"), 2 * GRID_RING)
	d.cellw = max(U.int(ih, "CELLWIDTH"), 32)
	d.imageh = max(math.floor(d.cellw / grid_aspect(ih) + 0.5), 16)
	local text = U.bool(ih, "SHOWTEXT") and 6 + 2 * (d.charh + 2) or 0
	d.cellh = d.imageh + text
	if d.horizontal then
		d.available = 0
		d.lanes = max(U.int(ih, "ROWS"), 1)
		d.pitch = d.cellw + d.gutter
	else
		d.available = (st.w or 0) - 2 * d.padding - bar
		d.lanes = max(idiv(d.available + d.gutter, d.cellw + d.gutter), 1)
		d.pitch = d.cellh + d.gutter
	end
end

local function grid_lines(ih) local d = D(ih); return idiv(d.count + d.lanes - 1, d.lanes) end
local function grid_total(ih)
	local d = D(ih)
	local lines = grid_lines(ih)
	return lines ~= 0 and 2 * d.padding + lines * d.pitch - d.gutter or 0
end
local function grid_extent(ih) local st = Element.state(ih); return D(ih).horizontal and st.w or st.h end
local function grid_scroll(ih) return U.int(ih, D(ih).horizontal and "POSX" or "POSY") end
local function grid_set_scroll(ih, value)
	-- the flat scrollbar's POSX/POSY setter keeps the position inside 0..MAX-D
	local d = D(ih)
	local maxv = U.int(ih, d.horizontal and "XMAX" or "YMAX") - U.int(ih, d.horizontal and "DX" or "DY")
	value = math.max(0, math.min(value, math.max(0, maxv)))
	Element.setAttribute(ih, d.horizontal and "POSX" or "POSY", tostring(value))
	FlatScrollbar.sync(ih)
end

-- The cell's corner on the canvas. Lanes spread to fill the width, so both edges of a vertical
-- grid sit on the padding; the spare pixels go in the gutters and the cell keeps its size,
-- which is what lets one decoded image serve every window width.
local function grid_cell_xy(ih, pos)
	local d = D(ih)
	local lane, line = imod(pos - 1, d.lanes), idiv(pos - 1, d.lanes)
	local along = d.padding + line * d.pitch - grid_scroll(ih)
	if d.horizontal then
		return along, d.padding + lane * (d.cellh + d.gutter)
	end
	return d.padding + (d.lanes > 1 and idiv(lane * (d.available - d.cellw), d.lanes - 1) or 0), along
end

local function grid_hit(ih, x, y)
	local d = D(ih)
	local across, along = d.horizontal and y or x, (d.horizontal and x or y) + grid_scroll(ih) - d.padding
	local span = d.horizontal and d.cellw or d.cellh
	if along < 0 or d.lanes == 0 then return 0 end
	local line = idiv(along, d.pitch)
	if imod(along, d.pitch) >= span then return 0 end
	for lane = 0, d.lanes - 1 do
		local pos = line * d.lanes + lane + 1
		if pos > d.count then return 0 end
		local cx, cy = grid_cell_xy(ih, pos)
		local start = d.horizontal and cy or cx
		local size = d.horizontal and d.cellh or d.cellw
		if across >= start and across < start + size then return pos end
	end
	return 0
end

local function grid_first(ih)
	local d = D(ih)
	return (d.lanes ~= 0 and d.pitch ~= 0) and idiv(grid_scroll(ih), d.pitch) * d.lanes + 1 or 1
end

-- A resize keeps the first cell in view where it is, whatever the lanes become.
local function grid_refresh(ih)
	local d, st = D(ih), Element.state(ih)
	local first, scrolled = grid_first(ih), grid_scroll(ih) > 0
	grid_measure(ih)
	local total = grid_total(ih)
	local set = function(n, v) st.attrs[n] = tostring(v) end
	if d.horizontal then
		set("XMAX", total); set("DX", max(st.w or 0, 1))
		set("YMAX", 0); set("DY", max(st.h or 0, 1))
		set("LINEX", idiv(d.pitch, 3))
	else
		set("YMAX", total); set("DY", max(st.h or 0, 1))
		set("XMAX", 0); set("DX", max(st.w or 0, 1))
		set("LINEY", idiv(d.pitch, 3))
	end
	if scrolled then grid_set_scroll(ih, idiv(first - 1, d.lanes) * d.pitch) end
	FlatScrollbar.sync(ih)
end

-- ---- painting ------------------------------------------------------------------------

local function grid_is_marked(ih, pos)
	local d = D(ih)
	if d.marks then return d.marks[pos] == true end
	return pos == d.cursor
end

local function grid_draw_cell(ih, dc, ox, oy, pos, x, y, p)
	local d = D(ih)
	local w, h = d.cellw, d.imageh
	local bits, stride
	if p.bits then bits, stride = U.bits(ih, "CELLBITS_CB", pos, w, h) end
	local title = grid_value(ih, "TITLE", pos)
	local badge = grid_value(ih, "BADGE", pos)
	local progress = grid_value(ih, "PROGRESS", pos)
	local state = grid_value(ih, "STATE", pos)
	local offline = state and U.eqnc(state, "offline")

	-- iupdrvDrawBits copies the cell's pixels; grid_draw_corners then paints the outside of
	-- each corner in the background colour: one rounded image does both.
	local drawn = bits and dc:bits(bits, w, h, stride, ox + x, oy + y, { radius = p.radius }) or false
	if not drawn then
		-- no pixels (yet): the placeholder, rounded as the corner tiles round it, and the
		-- title wrapped in the middle
		dc:fill(ox + x, oy + y, w, h, p.placeholder, { radius = p.radius })
		if title then -- wrapped text ignores vertical centring, so the box is placed by hand
			U.text(dc, ox, oy, title, x + 8, y + idiv(h, 2) - d.charh - 2, w - 16, idiv(h, 2), p.secondary, p.font,
				U.CENTER + U.WRAP + U.CLIP)
		end
	end
	if progress and atoi(progress) > 0 then
		local value, left, right, top = min(atoi(progress), 100), x + 6, x + w - 7, y + h - 10
		U.fill(dc, ox, oy, left, top, right, top + 3, U.rgba(16, 16, 20, 255))
		U.fill(dc, ox, oy, left, top, left + idiv((right - left) * value, 100), top + 3, p.marker)
	end
	if badge and badge ~= "" then
		local tw, th = U.stringwidth(p.font, badge) + 10, d.charh + 2
		local bx, by = x + w - tw - 6, y + 6
		U.fill(dc, ox, oy, bx, by, bx + tw - 1, by + th - 1, p.bg)
		U.text(dc, ox, oy, badge, bx, by, tw, th, p.fg, p.font, U.CENTER + U.LAYOUTCENTER + U.CLIP)
	end
	if state and U.eqnc(state, "unplayed") then
		U.fill(dc, ox, oy, x + 6, y + 6, x + 11, y + 11, p.marker)
	end
	if grid_is_marked(ih, pos) then
		FlatDraw.roundBorder(dc, ox, oy, x - 2, x + w + 1, y - 2, y + h + 1, p.radius + 2, 2, p.markername, p.bgname, true)
	elseif pos == d.hover and p.hoverbg then
		FlatDraw.roundBorder(dc, ox, oy, x - 1, x + w, y - 1, y + h, p.radius + 1, 1, p.hoverbg, p.bgname, true)
	end
	if d.focused and pos == d.cursor and p.focusring then
		FlatDraw.roundBorder(dc, ox, oy, x - 4, x + w + 3, y - 4, y + h + 3, p.radius + 4, 1, p.fgname, p.bgname, true)
	end

	if p.showtext then
		local line, ty = d.charh + 2, y + h + 6
		if title then
			U.text(dc, ox, oy, title, x, ty, w, line, offline and p.secondary or p.fg, p.font, U.LEFT + U.ELLIPSIS)
		end
		local secondary = grid_value(ih, "SECONDARY", pos)
		if secondary then
			U.text(dc, ox, oy, secondary, x, ty + line, w, line, p.secondary, p.font, U.LEFT + U.ELLIPSIS)
		end
	end
end

local function grid_redraw(ih, st, dc)
	local d = D(ih)
	local w, h = st.w, st.h
	local _, charh = U.charsize(ih)
	if d.measured_w ~= w or d.measured_h ~= h then
		d.measured_w, d.measured_h = w, h
		grid_refresh(ih) -- RESIZE_CB
	elseif charh ~= d.charh then
		grid_refresh(ih) -- a theme changed the font: the text lines changed height
	end
	FlatScrollbar.sync(ih)
	local ox, oy = st.x, st.y
	local p = {}
	p.bgname = U.attr(ih, "BGCOLOR")
	p.bg = U.strcolor(p.bgname, U.rgba(255, 255, 255, 255))
	p.fgname = U.attr(ih, "FGCOLOR")
	p.fg = U.strcolor(p.fgname, U.rgba(30, 30, 30, 255))
	p.secondary = U.strcolor(U.attr(ih, "SECONDARYCOLOR"), p.fg)
	p.placeholder = U.strcolor(U.attr(ih, "PLACEHOLDERCOLOR"), p.bg)
	p.markername = U.attr(ih, "ITEMMARKERCOLOR") or U.attr(ih, "FGCOLOR")
	p.marker = U.strcolor(p.markername, p.fg)
	p.hoverbg = U.attr(ih, "HLCOLOR")
	p.font = U.font(ih)
	p.radius = max(U.int(ih, "ITEMRADIUS"), 0)
	p.focusring = U.int(ih, "FOCUSFEEDBACK") ~= 0
	p.showtext = U.bool(ih, "SHOWTEXT")
	p.bits = U.has(ih, "CELLBITS_CB")

	dc:clip_push(st.x, st.y, w, h)
	U.fill(dc, ox, oy, 0, 0, w - 1, h - 1, p.bg)
	if d.count == 0 then
		local empty, hint = U.attr(ih, "EMPTYTITLE"), U.attr(ih, "EMPTYHINT")
		if empty then U.text(dc, ox, oy, empty, 16, idiv(h, 2) - 22, w - 32, 26, p.fg, p.font, U.CENTER + U.LAYOUTCENTER + U.ELLIPSIS) end
		if hint then U.text(dc, ox, oy, hint, 16, idiv(h, 2) + 5, w - 32, 22, p.secondary, p.font, U.CENTER + U.LAYOUTCENTER + U.ELLIPSIS) end
	end
	local scroll = grid_scroll(ih)
	local extent = d.horizontal and w or h
	local line = idiv(max(scroll - d.padding, 0), d.pitch)
	local lastline = idiv(scroll + extent, d.pitch)
	while line <= lastline do
		for lane = 0, d.lanes - 1 do
			local pos = line * d.lanes + lane + 1
			if pos > d.count then break end
			local x, y = grid_cell_xy(ih, pos)
			if not (x + d.cellw + GRID_RING <= 0 or x - GRID_RING >= w or y + d.cellh + GRID_RING <= 0 or y - GRID_RING >= h) then
				grid_draw_cell(ih, dc, ox, oy, pos, x, y, p)
			end
		end
		line = line + 1
	end
	dc:clip_pop()
end

-- Repaints one cell and whatever rings it has (here: the frame repaints).
local function grid_touch(ih, pos)
	local d = D(ih)
	if pos < 1 or pos > d.count then return end
	local Runtime = package.loaded["core.imgui.Runtime"]
	if Runtime and Runtime.redraw then Runtime.redraw(ih) end
end
local function post_redraw(ih)
	local Runtime = package.loaded["core.imgui.Runtime"]
	if Runtime and Runtime.redraw then Runtime.redraw(ih) end
end

-- ---- selection -----------------------------------------------------------------------

local function grid_mark_all(ih, on)
	local d = D(ih)
	if not d.marks then return end
	d.marks = {}
	if on then for i = 1, d.count do d.marks[i] = true end end
	d.marked = on and d.count or 0
end
local function grid_mark(ih, pos, on)
	local d = D(ih)
	if (d.marks[pos] == true) == (on and true or false) then return end
	if on then d.marks[pos] = true; d.marked = d.marked + 1
	else d.marks[pos] = nil; d.marked = d.marked - 1 end
end
local function grid_alloc_marks(ih)
	local d = D(ih)
	d.marks = nil
	d.marked = 0
	if U.bool(ih, "MULTIPLE") then d.marks = {} end
end

-- Brings a cell into view. Returns whether anything moved.
local function grid_reveal(ih, pos)
	local d = D(ih)
	local scroll, extent, span = grid_scroll(ih), grid_extent(ih), d.horizontal and d.cellw or d.cellh
	local along, nextv = d.padding + idiv(pos - 1, d.lanes) * d.pitch, scroll
	if along - GRID_RING < scroll then nextv = max(along - GRID_RING, 0)
	elseif along + span + GRID_RING > scroll + extent then nextv = along + span + GRID_RING - extent end
	if nextv == scroll then return false end
	grid_set_scroll(ih, nextv)
	return true
end

local function grid_go(ih, pos, mode)
	local d = D(ih)
	local before = d.cursor
	if d.count == 0 then return iup.IGNORE end
	pos = max(min(pos, d.count), 1)
	local changed = pos ~= before
	if d.marks then
		if mode == GRID_TOGGLE then
			grid_mark(ih, pos, not grid_is_marked(ih, pos))
			changed = true
		else
			changed = changed or d.marked ~= 1 or not grid_is_marked(ih, pos)
			if d.marked ~= 0 then grid_mark_all(ih, false) end
			local a = (mode == GRID_EXTEND and d.anchor ~= 0) and d.anchor or pos
			local from, to = min(a, pos), max(a, pos)
			for i = from, to do grid_mark(ih, i, true) end
		end
	end
	d.cursor = pos
	if mode ~= GRID_EXTEND then d.anchor = pos end
	grid_reveal(ih, pos)
	grid_touch(ih, before); grid_touch(ih, pos)
	if changed then
		U.call(ih, "CELL_ACTION_CB", pos)
		U.call(ih, "VALUECHANGED_CB")
	end
	return iup.IGNORE
end

local function grid_activate(ih, pos, how)
	if pos ~= 0 then U.call(ih, "CELL_ACTIVATE_CB", pos, how) end
	return iup.IGNORE
end

-- ---- input ---------------------------------------------------------------------------

local function grid_title_matches(title, typed)
	return title:sub(1, #typed):lower() == typed:lower()
end

local function grid_type_ahead(ih, c)
	local d = D(ih)
	d.typed_at = grid_ticks()
	if #d.typed < GRID_TYPEAHEAD_MAX then d.typed = d.typed .. string.char(c) end
	local len = #d.typed
	if U.has(ih, "TYPEAHEAD_CB") then
		-- grid_typeahead_cb: a number from the provider, else -1 (scan the titles)
		local r = U.call(ih, "TYPEAHEAD_CB", d.typed)
		local pos = type(r) == "number" and math.floor(r) or -1
		if pos >= 0 then
			if pos > 0 then grid_go(ih, pos, GRID_PLAIN) end
			return iup.IGNORE
		end
	end
	local start = d.cursor ~= 0 and d.cursor or 1
	if len == 1 then start = start % d.count + 1 end -- the same letter again moves on
	local pos = start
	for _ = 1, d.count do
		local title = grid_value(ih, "TITLE", pos)
		if title and grid_title_matches(title, d.typed) then grid_go(ih, pos, GRID_PLAIN); break end
		pos = pos % d.count + 1
	end
	return iup.IGNORE
end

local function grid_key(ih, c)
	local d = D(ih)
	local base, ctrl, shift = iup.XkeyBase(c), iup.isCtrlXkey(c), iup.isShiftXkey(c)
	local mode = shift and GRID_EXTEND or GRID_PLAIN
	local across, down = d.horizontal and d.lanes or 1, d.horizontal and 1 or d.lanes
	local page = max(idiv(grid_extent(ih), d.pitch), 1) * d.lanes
	local target
	if d.count == 0 then return iup.CONTINUE end
	if base == iup.K_LEFT then target = d.cursor - across
	elseif base == iup.K_RIGHT then target = d.cursor + across
	elseif base == iup.K_UP then target = d.cursor - down
	elseif base == iup.K_DOWN then target = d.cursor + down
	elseif base == iup.K_PGUP then return grid_go(ih, d.cursor - page, mode)
	elseif base == iup.K_PGDN then return grid_go(ih, d.cursor + page, mode)
	elseif base == iup.K_HOME then return grid_go(ih, 1, mode)
	elseif base == iup.K_END then return grid_go(ih, d.count, mode)
	elseif base == iup.K_CR then return grid_activate(ih, d.cursor, "enter")
	else
		if ctrl and (base == string.byte("a") or base == string.byte("A")) and d.marks then
			grid_mark_all(ih, true)
			post_redraw(ih)
			U.call(ih, "VALUECHANGED_CB")
			return iup.IGNORE
		end
		if ctrl or iup.isAltXkey(c) or iup.isSysXkey(c) or not iup.isprint(base) then return iup.CONTINUE end
		if grid_ticks() - d.typed_at > GRID_TYPEAHEAD_MS then d.typed = "" end
		if base == iup.K_SP and d.typed == "" then -- a title has spaces, so only a word in progress takes one
			if d.marks and d.cursor ~= 0 then return grid_go(ih, d.cursor, GRID_TOGGLE) end
			return iup.CONTINUE
		end
		return grid_type_ahead(ih, base)
	end
	-- Past the last line, the last cell, once. Sideways off either end stays put.
	if d.cursor == 0 then return grid_go(ih, 1, mode) end
	if target > d.count then
		target = idiv(d.cursor - 1, d.lanes) < idiv(d.count - 1, d.lanes) and d.count or d.cursor
	end
	if target < 1 then target = d.cursor end
	return grid_go(ih, target, mode)
end

local function grid_button(ih, button, pressed, x, y, status, rt)
	local d = D(ih)
	if not pressed then return iup.DEFAULT end
	if U.bool(ih, "CANFOCUS") and rt and rt.setFocus then rt.setFocus(ih) end
	local pos = grid_hit(ih, x, y)
	if pos == 0 then return iup.DEFAULT end
	if button == iup.BUTTON3 then
		if not grid_is_marked(ih, pos) then grid_go(ih, pos, GRID_PLAIN) end
		U.call(ih, "CELL_CONTEXT_CB", pos, "context")
		return iup.DEFAULT
	end
	if button ~= iup.BUTTON1 then return iup.DEFAULT end
	local mode = not d.marks and GRID_PLAIN or iup.iscontrol(status) and GRID_TOGGLE or iup.isshift(status) and GRID_EXTEND or GRID_PLAIN
	grid_go(ih, pos, mode)
	if iup.isdouble(status) then grid_activate(ih, pos, "double") end
	return iup.DEFAULT
end

local function grid_set_hover(ih, pos)
	local d = D(ih)
	local before = d.hover
	if pos == before then return end
	d.hover = pos
	grid_touch(ih, before)
	grid_touch(ih, pos)
end
local function grid_motion(ih, x, y) grid_set_hover(ih, grid_hit(ih, x, y)) end
local function grid_leave(ih) grid_set_hover(ih, 0) end
local function grid_focus(ih, focus)
	D(ih).focused = focus
	grid_touch(ih, D(ih).cursor)
end
-- The list moved under a still pointer, and no motion event will say so.
local function grid_rehover(ih, x, y)
	local st = Element.state(ih)
	D(ih).hover = (x and y and x >= 0 and y >= 0 and x < st.w and y < st.h) and grid_hit(ih, x, y) or 0
end
local function grid_wheel(ih, delta, x, y)
	local d = D(ih)
	if d.horizontal then
		local nextv = grid_scroll(ih) - math.floor(delta * idiv(d.pitch, 3))
		grid_set_scroll(ih, max(min(nextv, grid_total(ih) - grid_extent(ih)), 0))
	else
		local liney = U.int(ih, "LINEY")
		grid_set_scroll(ih, grid_scroll(ih) - math.floor(delta * (liney ~= 0 and liney or 1)))
	end
	U.call(ih, "SCROLL_CB", 0, U.int(ih, "POSX"), U.int(ih, "POSY"))
	grid_rehover(ih, x, y)
	post_redraw(ih)
	return iup.DEFAULT
end

-- ---- class ---------------------------------------------------------------------------

local function grid_size(ih)
	local d = D(ih)
	grid_measure(ih)
	return d.cellw * 2 + d.gutter + 2 * d.padding, d.cellh + 2 * d.padding
end

local function grid_set_count(ih, st, value)
	local d = D(ih)
	local n = atoi(value)
	d.count = n > 0 and n or 0
	if d.cursor > d.count then d.cursor = 0 end
	if d.anchor > d.count then d.anchor = 0 end
	if d.hover > d.count then d.hover = 0 end
	grid_alloc_marks(ih)
	grid_refresh(ih)
	return false
end
local function grid_set_value(ih, st, value)
	local d = D(ih)
	local pos, before = atoi(value), d.cursor
	d.cursor = (pos >= 1 and pos <= d.count) and pos or 0
	d.anchor = d.cursor
	if d.marks then
		grid_mark_all(ih, false)
		if d.cursor ~= 0 then grid_mark(ih, d.cursor, true) end
		post_redraw(ih)
	else grid_touch(ih, before); grid_touch(ih, d.cursor) end
	return false
end
local function grid_set_scrollto(ih, st, value)
	local d = D(ih)
	local pos = atoi(value)
	if pos < 1 or pos > d.count then return false end
	grid_set_scroll(ih, max(min(idiv(pos - 1, d.lanes) * d.pitch, grid_total(ih) - grid_extent(ih)), 0))
	post_redraw(ih)
	return false
end
local function grid_get_visiblerange(ih)
	local d = D(ih)
	if d.count == 0 then return nil end
	local first = idiv(max(grid_scroll(ih) - d.padding, 0), d.pitch) * d.lanes + 1
	local last = min((idiv(grid_scroll(ih) + grid_extent(ih), d.pitch) + 1) * d.lanes, d.count)
	return string.format("%d:%d", first, last)
end
local function grid_get_selectionmask(ih)
	local d = D(ih)
	if d.count == 0 then return nil end
	local mask = {}
	for pos = 1, d.count do mask[pos] = grid_is_marked(ih, pos) and "+" or "-" end
	return table.concat(mask)
end
local function grid_get_accessible(ih)
	local pos = D(ih).cursor
	return pos ~= 0 and grid_value(ih, "TITLE", pos) or nil
end
-- GRID_LAYOUT_ATTRIB: store, then measure again
local function relayout(name)
	return function(ih, st, value)
		st.attrs[name] = value
		grid_refresh(ih)
		return false
	end
end

local function grid_event(ih, st, ev, rt)
	local d = D(ih)
	if ev.type == "press" or ev.type == "release" then
		grid_button(ih, ev.button == 1 and iup.BUTTON1 or ev.button == 2 and iup.BUTTON2 or iup.BUTTON3,
			ev.type == "press", ev.lx, ev.ly, ev.status or "", rt)
		return true
	elseif ev.type == "move" or ev.type == "enter" then
		grid_motion(ih, ev.lx, ev.ly)
		return true
	elseif ev.type == "leave" then
		grid_leave(ih)
		return true
	elseif ev.type == "focus" then
		grid_focus(ih, true)
		return true
	elseif ev.type == "blur" then
		grid_focus(ih, false)
		return true
	elseif ev.type == "wheel" then
		grid_wheel(ih, ev.dy or 0, ev.lx, ev.ly)
		return true
	elseif ev.type == "key" or ev.type == "char" then
		-- K_ANY: a printable key arrives as a character (its code point), the rest as keys
		local r = grid_key(ih, ev.key or 0)
		return r == iup.IGNORE
	end
	return false
end

Classes.define{
	name = "flatgrid", children = 0, focusable = true,
	expandDefault = "YES", -- a canvas (iCanvasCreateMethod: IUP_EXPAND_BOTH); grid_create keeps it
	visibleChildren = FlatScrollbar.visible_children,
	-- iupFlatGridNewClass registrations
	defaults = {
		BORDER = "NO", COUNT = "0", VALUE = "0", CELLWIDTH = "150", ASPECT = "2:3", GUTTER = "16",
		PADDING = "16", ROWS = "1", ORIENTATION = "VERTICAL", SHOWTEXT = "YES", MULTIPLE = "NO",
		ITEMRADIUS = "6", FOCUSFEEDBACK = "YES", FLATSCROLLBAR = "YES",
		-- grid_create
		EXPAND = "YES", SCROLLBAR = "YES", -- the flat bars show where XMAX/YMAX need them
		-- iupFlatScrollBarRegister
		SCROLLBARSIZE = "15",
	},
	callbacks = {
		CELLVALUE_CB = true, CELLBITS_CB = true, CELL_ACTION_CB = true, CELL_ACTIVATE_CB = true,
		CELL_CONTEXT_CB = true, TYPEAHEAD_CB = true, VALUECHANGED_CB = true,
	},
	create = function(ih, st)
		D(ih)
		FlatScrollbar.create(ih)
	end,
	natural = function(ih) return grid_size(ih) end,
	-- RESIZE_CB: only a size change measures again (it also snaps the scroll to a line)
	place = function(ih, st)
		local d = D(ih)
		if d.measured_w ~= st.w or d.measured_h ~= st.h then
			d.measured_w, d.measured_h = st.w, st.h
			grid_refresh(ih)
		end
	end,
	draw = function(ih, st, dc) grid_redraw(ih, st, dc) end,
	event = grid_event,
	set = {
		COUNT = grid_set_count,
		VALUE = grid_set_value,
		CELLWIDTH = relayout("CELLWIDTH"), ASPECT = relayout("ASPECT"), GUTTER = relayout("GUTTER"),
		PADDING = relayout("PADDING"), ROWS = relayout("ROWS"), ORIENTATION = relayout("ORIENTATION"),
		SHOWTEXT = relayout("SHOWTEXT"),
		MULTIPLE = function(ih, st, value) st.attrs.MULTIPLE = value; grid_alloc_marks(ih); return false end,
		SCROLLTO = grid_set_scrollto,
		REDRAWCELL = function(ih, st, value) grid_touch(ih, atoi(value)); return false end,
		POSX = function(ih, st, value) st.attrs.POSX = value; return false end,
		POSY = function(ih, st, value) st.attrs.POSY = value; return false end,
	},
	get = {
		COUNT = function(ih) return D(ih).count end,
		VALUE = function(ih) return D(ih).cursor end,
		VISIBLERANGE = grid_get_visiblerange,
		HOVER = function(ih) return D(ih).hover end,
		SELECTEDCOUNT = function(ih) local d = D(ih); return d.marks and d.marked or (d.cursor ~= 0 and 1 or 0) end,
		SELECTIONMASK = grid_get_selectionmask,
		ACCESSIBLEVALUE = grid_get_accessible,
		VALUESTRING = grid_get_accessible,
	},
	destroy = function(ih, st) end,
}

-- for tests
M._hit = grid_hit
M._cell_xy = grid_cell_xy
M._measure = grid_measure
return M
