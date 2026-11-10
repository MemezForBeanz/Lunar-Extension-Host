--- Port of Lunar's IupFlatRows (iup-fork patches 0020 and 0022, src/iup_flatrows.c): a virtual
-- row list. Only visible rows are queried and painted.
--
-- C function -> Lua (same names):
--   rows_height, rows_header, rows_count, rows_column_flag, rows_image_size,
--   rows_column_widths, rows_touch, rows_value, rows_refresh, rows_set_count, rows_get_count,
--   rows_get_hover, rows_set_value, rows_get_value, rows_get_accessible, rows_draw_header,
--   rows_redraw (the class draw), rows_select, rows_column_at, rows_button, rows_motion,
--   rows_leave, rows_focus, rows_up, rows_down, rows_home, rows_end, rows_page, rows_pgup,
--   rows_pgdn, rows_enter, rows_wheel, rows_scroll (rows_rehover), rows_resize (place),
--   rows_set_scrollbar (create: the flat scrollbar always exists), rows_post_redraw (the
--   frame repaints), rows_set_header, rows_set_header_height, rows_set_height, rows_size
--   (natural), rows_child_size / rows_child_pos (FlatScrollbar.sync), rows_destroy,
--   rows_create (create), iupFlatRowsNewClass (Classes.define)
--   rows_get_idvalue: IDVALUEn is answered by the `getId` hook below
-- @module core.imgui.widgets.flatrows
local Classes = require("core.imgui.Classes")
local Element = require("core.imgui.Element")
local iup = require("core.imgui.iup")
local FlatDraw = require("core.imgui.widgets.flatdraw")
local FlatScrollbar = require("core.imgui.widgets.flatscrollbar")
local U = require("core.imgui.widgets.rawutil")

local M = {}

local ROWS_COLUMNS = 6
local idiv, atoi = U.idiv, U.atoi
local function init_data(d)
	d._init = true
	d.count, d.selected, d.hover, d.focused = 0, 0, 0, false
end
-- ih->data: the class data, made on first use (IUP runs Create before any attribute)
local function D(ih)
	local d = Element.state(ih).data
	if not d._init then init_data(d) end
	return d
end
local function own(ih, n) return Element.own(ih, n) end
local function redraw(ih)
	local Runtime = package.loaded["core.imgui.Runtime"]
	if Runtime and Runtime.redraw then Runtime.redraw(ih) end
end

local function rows_height(ih)
	local height = U.int(ih, "ROWHEIGHT")
	return height < 20 and 20 or height > 400 and 400 or height
end
local function rows_header(ih) return U.bool(ih, "HEADER") and U.int(ih, "HEADERHEIGHT") or 0 end
local function rows_count(ih) return D(ih).count end
-- Numbers line up on the right; a column set to LEFT holds text, which reads from its start.
local function rows_column_flag(ih, slot)
	local value = U.attr(ih, "COLUMN" .. slot .. "ALIGN")
	return (value and U.eqnc(value, "LEFT")) and U.LEFT or U.RIGHT
end

local function rows_image_size(ih)
	local value = U.attr(ih, "IMAGESIZE")
	local w, h = 16, 16
	if value then
		local a, b = tostring(value):match("^%s*(%-?%d+)x(%-?%d+)")
		if a then w, h = tonumber(a), tonumber(b)
		else
			a = tostring(value):match("^%s*(%-?%d+)")
			if a then w = tonumber(a); h = w end
		end
	end
	return w, h
end
local function rows_column_widths(ih)
	local widths = {}
	for slot = 1, ROWS_COLUMNS do widths[slot] = U.int(ih, "COLUMN" .. slot .. "WIDTH") end
	return widths
end
-- The band a position's row covers, for repainting it alone (here: the frame repaints).
local function rows_touch(ih, pos)
	if pos < 1 or pos > D(ih).count then return end
	redraw(ih)
end
local function rows_value(ih, field, pos)
	local value = own(ih, field .. pos)
	if value == nil then value = U.value(ih, "ROWVALUE_CB", pos, field) end
	return value
end
local function rows_refresh(ih)
	local st = Element.state(ih)
	local total = rows_count(ih) * rows_height(ih) + rows_header(ih)
	st.attrs.YMAX = tostring(total)
	st.attrs.DY = tostring((st.h or 0) > 0 and st.h or 1)
	st.attrs.XMAX = "0" -- rows never scroll sideways; this is what hides that bar
	st.attrs.DX = tostring((st.w or 0) > 0 and st.w or 1)
	-- the scrollbar's POSY setter keeps the position in range
	local posy = U.int(ih, "POSY")
	local maxy = math.max(0, total - ((st.h or 0) > 0 and st.h or 1))
	if posy > maxy then st.attrs.POSY = tostring(maxy) end
	FlatScrollbar.sync(ih)
	redraw(ih)
end
local function rows_set_count(ih, st, value)
	local n = atoi(value)
	D(ih).count = n > 0 and n or 0
	if D(ih).selected > D(ih).count then D(ih).selected = 0 end
	rows_refresh(ih)
	return false
end
local function rows_set_value(ih, st, value)
	local pos = atoi(value)
	D(ih).selected = (pos >= 1 and pos <= D(ih).count) and pos or 0
	redraw(ih)
	return false
end
local function rows_get_accessible(ih)
	local pos = D(ih).selected
	return pos ~= 0 and rows_value(ih, "TITLE", pos) or nil
end

local function rows_draw_header(ih, dc, ox, oy, w, widths, title_x)
	local header, right = rows_header(ih), w - 12
	local sorted = U.bool(ih, "SORTED") and U.int(ih, "SORTCOLUMN") or -1
	local ascending = not U.eqnc(U.attr(ih, "SORTDIR"), "DESC")
	local bg = U.attr(ih, "HEADERCOLOR")
	local fg = U.attr(ih, "SECONDARYCOLOR")
	local font = U.font(ih)
	local title = U.attr(ih, "HEADERTITLE")
	if not bg then bg = U.attr(ih, "BGCOLOR") end
	if not fg then fg = U.attr(ih, "FGCOLOR") end
	local text = U.strcolor(fg, U.rgba(30, 30, 30, 255))
	local _, charheight = font:charsize()
	U.fill(dc, ox, oy, 0, 0, w - 1, header - 1, U.strcolor(bg, U.rgba(255, 255, 255, 255)))
	U.fill(dc, ox, oy, 0, header - 1, w - 1, header - 1, U.strcolor(U.attr(ih, "BORDERCOLOR"), text))
	for slot = ROWS_COLUMNS, 1, -1 do
		if widths[slot] > 0 then
			right = right - widths[slot]
			local label = U.attr(ih, "HEADER" .. slot)
			if label then
				U.text(dc, ox, oy, label, right, idiv(header - charheight, 2), widths[slot] - 8, charheight, text, font,
					rows_column_flag(ih, slot) + U.LAYOUTCENTER + U.ELLIPSIS)
				local textw = U.stringwidth(font, label)
				if sorted == slot then
					U.arrow(dc, ox, oy, right + widths[slot] - 8 - textw - 12, idiv(header - 8, 2), 8, fg, bg, true,
						ascending and U.ARROW_TOP or U.ARROW_BOTTOM)
				end
			end
		end
	end
	if title then
		U.text(dc, ox, oy, title, title_x, idiv(header - charheight, 2), right - title_x, charheight, text, font,
			U.LEFT + U.LAYOUTCENTER + U.ELLIPSIS)
		if sorted == 0 then
			U.arrow(dc, ox, oy, title_x + U.stringwidth(font, title) + 4, idiv(header - 8, 2), 8, fg, bg, true,
				ascending and U.ARROW_TOP or U.ARROW_BOTTOM)
		end
	end
end

local function rows_redraw(ih, st, dc)
	local d = D(ih)
	if d.measured_w ~= st.w or d.measured_h ~= st.h then
		d.measured_w, d.measured_h = st.w, st.h
		rows_refresh(ih) -- RESIZE_CB
	end
	FlatScrollbar.sync(ih)
	local ox, oy, w, h = st.x, st.y, st.w, st.h
	local rh, scroll = rows_height(ih), U.int(ih, "POSY")
	local header = rows_header(ih)
	local image_w, image_h = rows_image_size(ih)
	local widths = rows_column_widths(ih)
	local title_x = 12
	local bg = U.attr(ih, "BGCOLOR")
	local fg = U.attr(ih, "FGCOLOR")
	local font = U.font(ih)
	local placeholder = U.attr(ih, "PLACEHOLDERCOLOR")
	local marker = U.attr(ih, "ITEMMARKERCOLOR")
	local bgc = U.strcolor(bg, U.rgba(255, 255, 255, 255))
	local fgc = U.strcolor(fg, U.rgba(30, 30, 30, 255))
	local secondaryc = U.strcolor(U.attr(ih, "SECONDARYCOLOR"), fgc)
	local markerc = U.strcolor(marker, fgc)
	local bits = U.has(ih, "ROWBITS_CB")
	local _, charheight = font:charsize()
	if bits then title_x = title_x + image_w + 8 end
	dc:clip_push(ox, oy, w, h)
	U.fill(dc, ox, oy, 0, 0, w - 1, h - 1, bgc)
	if d.count == 0 then
		local empty, hint = U.attr(ih, "EMPTYTITLE"), U.attr(ih, "EMPTYHINT")
		if empty then U.text(dc, ox, oy, empty, 16, idiv(h, 2) - 22, w - 32, 26, fgc, font, U.CENTER + U.LAYOUTCENTER + U.ELLIPSIS) end
		if hint then U.text(dc, ox, oy, hint, 16, idiv(h, 2) + 5, w - 32, 22, secondaryc, font, U.CENTER + U.LAYOUTCENTER + U.ELLIPSIS) end
	end
	local first = idiv(scroll, rh) + 1
	local last = idiv(scroll + h - header, rh) + 1
	if last > d.count then last = d.count end
	for pos = first, last do
		local y, x, right = header + (pos - 1) * rh - scroll, 12, w - 12
		local text_color = fgc
		if not (y + rh <= 0 or y >= h) then
			local line = y + idiv(rh - charheight, 2) -- the driver draws from the top of the box it is given
			local title = rows_value(ih, "TITLE", pos)
			local image = rows_value(ih, "IMAGE", pos)
			local secondary = rh >= 44 and rows_value(ih, "SECONDARY", pos) or nil
			local action = rows_value(ih, "ACTIONTEXT", pos)
			local progress = rows_value(ih, "PROGRESS", pos)
			local two_lines = idiv(rh - 37, 2) -- a 21 pixel title over a 16 pixel second line, centred
			if pos == d.selected then
				local fill = U.attr(ih, "PSCOLOR")
				local textps = U.attr(ih, "TEXTPSCOLOR")
				local fillc = U.strcolor(fill, bgc)
				local radius = U.int(ih, "ITEMRADIUS")
				if radius > 0 then FlatDraw.gradientBox(dc, ox, oy, 4, w - 5, y + 1, y + rh - 2, radius, fill, nil, true, bg, true)
				else U.fill(dc, ox, oy, 4, y, w - 5, y + rh - 1, fillc) end
				if marker then U.fill(dc, ox, oy, 5, y + 6, 7, y + rh - 7, markerc) end
				if textps then text_color = U.strcolor(textps, fgc) end
			elseif pos == d.hover then
				U.fill(dc, ox, oy, 4, y + 1, w - 5, y + rh - 2, U.strcolor(U.attr(ih, "HLCOLOR"), bgc))
			end
			if bits then
				local pixels, stride = U.bits(ih, "ROWBITS_CB", pos, image_w, image_h)
				local image_y = y + idiv(rh - image_h, 2)
				local drawn = pixels and dc:bits(pixels, image_w, image_h, stride, ox + x, oy + image_y) or false
				if not drawn then U.fill(dc, ox, oy, x, image_y, x + image_w - 1, image_y + image_h - 1, U.strcolor(placeholder, bgc)) end
				x = x + image_w + 8
			elseif image then
				FlatDraw.image(dc, ox, oy, image, false, bg, x, y + idiv(rh - image_h, 2), image_w, image_h)
				x = x + image_w + 8
			end
			if action and pos == d.hover then
				right = right - 54
				U.text(dc, ox, oy, action, right, line, 54, charheight, text_color, font, U.RIGHT + U.LAYOUTCENTER + U.CLIP)
			end
			for slot = ROWS_COLUMNS, 1, -1 do
				if widths[slot] > 0 then
					local value = rows_value(ih, "COLUMN" .. slot, pos)
					right = right - widths[slot]
					if value then
						U.text(dc, ox, oy, value, right, line, widths[slot] - 8, charheight, secondaryc, font,
							rows_column_flag(ih, slot) + U.LAYOUTCENTER + U.ELLIPSIS)
					end
				end
			end
			if title then
				U.text(dc, ox, oy, title, x, secondary and y + two_lines or line, right - x, secondary and 21 or charheight,
					text_color, font, U.LEFT + U.LAYOUTCENTER + U.ELLIPSIS)
			end
			if secondary then
				U.text(dc, ox, oy, secondary, x, y + two_lines + 20, right - x, 16, secondaryc, font, U.LEFT + U.ELLIPSIS)
			end
			if progress and atoi(progress) > 0 then
				local value, bottom = math.min(atoi(progress), 100), y + rh - 4
				U.fill(dc, ox, oy, x, bottom, right - 1, bottom + 1, secondaryc)
				U.fill(dc, ox, oy, x, bottom, x + idiv((right - 1 - x) * value, 100), bottom + 1, markerc)
			end
			if d.focused and pos == d.selected and U.int(ih, "FOCUSFEEDBACK") ~= 0 then
				U.focusrect(dc, ox, oy, 4, y + 1, w - 5, y + rh - 2, fg)
			end
		end
	end
	if header > 0 then rows_draw_header(ih, dc, ox, oy, w, widths, title_x) end
	dc:clip_pop()
end

local function set_posy(ih, v)
	local st = Element.state(ih)
	local maxy = math.max(0, U.int(ih, "YMAX") - U.int(ih, "DY"))
	st.attrs.POSY = tostring(math.max(0, math.min(v, maxy)))
	FlatScrollbar.sync(ih)
end

local function rows_select(ih, pos)
	local d, st = D(ih), Element.state(ih)
	if pos < 1 or pos > d.count then return iup.DEFAULT end
	if pos ~= d.selected then
		d.selected = pos
		U.call(ih, "ROW_ACTION_CB", pos)
		U.call(ih, "VALUECHANGED_CB")
	end
	if (pos - 1) * rows_height(ih) < U.int(ih, "POSY") then set_posy(ih, (pos - 1) * rows_height(ih))
	elseif pos * rows_height(ih) > U.int(ih, "POSY") + st.h - rows_header(ih) then
		set_posy(ih, pos * rows_height(ih) - st.h + rows_header(ih))
	end
	redraw(ih)
	return iup.DEFAULT
end
-- 0 is the title, 1 to ROWS_COLUMNS the columns.
local function rows_column_at(ih, x)
	local widths, right = rows_column_widths(ih), Element.state(ih).w - 12
	for slot = ROWS_COLUMNS, 1, -1 do
		if widths[slot] > 0 then
			right = right - widths[slot]
			if x >= right then return slot end
		end
	end
	return 0
end
local function rows_button(ih, button, pressed, x, y, status)
	local d, st = D(ih), Element.state(ih)
	local header = rows_header(ih)
	local pos = idiv(y - header + U.int(ih, "POSY"), rows_height(ih)) + 1
	if pressed and button == iup.BUTTON1 and y < header then
		U.call(ih, "HEADER_CB", rows_column_at(ih, x))
		return iup.DEFAULT
	end
	if not pressed or y < header or pos < 1 or pos > d.count then return iup.DEFAULT end
	if button == iup.BUTTON3 then U.call(ih, "ROW_CONTEXT_CB", pos, "context"); return iup.DEFAULT end
	if button ~= iup.BUTTON1 then return iup.DEFAULT end
	rows_select(ih, pos)
	U.call(ih, "ROW_PART_CB", pos, (rows_value(ih, "ACTIONTEXT", pos) and x >= st.w - 66) and "action" or "row")
	if iup.isdouble(status) then U.call(ih, "ROW_ACTIVATE_CB", pos, "double") end
	return iup.DEFAULT
end
local function rows_motion(ih, x, y)
	local d = D(ih)
	local header = rows_header(ih)
	local pos, before = idiv(y - header + U.int(ih, "POSY"), rows_height(ih)) + 1, d.hover
	if y < header or pos > d.count then pos = 0 end
	if pos ~= before then
		d.hover = pos
		rows_touch(ih, before)
		rows_touch(ih, pos)
	end
	return iup.DEFAULT
end
local function rows_leave(ih)
	local before = D(ih).hover
	D(ih).hover = 0
	rows_touch(ih, before)
	return iup.DEFAULT
end
local function rows_focus(ih, focus) D(ih).focused = focus; redraw(ih); return iup.DEFAULT end
local function rows_up(ih) local s = D(ih).selected; return rows_select(ih, s > 1 and s - 1 or 1) end
local function rows_down(ih) return rows_select(ih, D(ih).selected + 1) end
local function rows_home(ih) return rows_select(ih, 1) end
local function rows_end(ih) return rows_select(ih, D(ih).count) end
local function rows_page(ih) return idiv(Element.state(ih).h - rows_header(ih), rows_height(ih)) end
local function rows_pgup(ih)
	local pos = D(ih).selected - rows_page(ih)
	return rows_select(ih, pos < 1 and 1 or pos)
end
local function rows_pgdn(ih)
	local pos = D(ih).selected + rows_page(ih)
	return rows_select(ih, pos > D(ih).count and D(ih).count or pos)
end
local function rows_enter(ih)
	local s = D(ih).selected
	if s ~= 0 then U.call(ih, "ROW_ACTIVATE_CB", s, "enter") end
	return iup.IGNORE
end
-- rows_scroll: the rows moved under a still pointer, and no motion event will say so.
local function rows_rehover(ih, x, y)
	local d, st = D(ih), Element.state(ih)
	if not (x and y) then redraw(ih); return end
	local header = rows_header(ih)
	local pos = idiv(y - header + U.int(ih, "POSY"), rows_height(ih)) + 1
	d.hover = (x >= 0 and x < st.w and y >= header and y < st.h and pos <= d.count) and pos or 0
	redraw(ih)
end
local function rows_wheel(ih, delta, x, y)
	local liney = U.int(ih, "LINEY")
	set_posy(ih, U.int(ih, "POSY") - math.floor(delta * (liney ~= 0 and liney or 1)))
	U.call(ih, "SCROLL_CB", 0, 0, U.int(ih, "POSY"))
	rows_rehover(ih, x, y)
	return iup.DEFAULT
end

local KEYS = {
	[iup.K_UP] = rows_up, [iup.K_DOWN] = rows_down, [iup.K_HOME] = rows_home, [iup.K_END] = rows_end,
	[iup.K_PGUP] = rows_pgup, [iup.K_PGDN] = rows_pgdn, [iup.K_CR] = rows_enter,
}

local function rows_event(ih, st, ev, rt)
	if ev.type == "press" or ev.type == "release" then
		rows_button(ih, ev.button == 1 and iup.BUTTON1 or ev.button == 2 and iup.BUTTON2 or iup.BUTTON3,
			ev.type == "press", ev.lx, ev.ly, ev.status or "")
		return true
	elseif ev.type == "move" or ev.type == "enter" then
		rows_motion(ih, ev.lx, ev.ly)
		return true
	elseif ev.type == "leave" then
		rows_leave(ih)
		return true
	elseif ev.type == "focus" then rows_focus(ih, true); return true
	elseif ev.type == "blur" then rows_focus(ih, false); return true
	elseif ev.type == "wheel" then
		rows_wheel(ih, ev.dy or 0, ev.lx, ev.ly)
		return true
	elseif ev.type == "key" then
		-- K_UP, K_DOWN... are callbacks in the C: only the plain key, as IUP looks them up
		local fn = KEYS[ev.key or 0]
		if fn then fn(ih); return true end
	end
	return false
end

local function relayout(name)
	return function(ih, st, value) st.attrs[name] = value; rows_refresh(ih); return false end
end

Classes.define{
	name = "flatrows", children = 0, focusable = true,
	visibleChildren = FlatScrollbar.visible_children,
	defaults = {
		BORDER = "NO", COUNT = "0", VALUE = "0", ROWHEIGHT = "32", ITEMRADIUS = "6", FOCUSFEEDBACK = "YES",
		IMAGESIZE = "16", HEADER = "NO", HEADERHEIGHT = "28", SORTED = "NO", SORTCOLUMN = "0", SORTDIR = "ASC",
		FLATSCROLLBAR = "YES",
		-- rows_create
		EXPAND = "YES", SCROLLBAR = "YES", -- the flat bars show where XMAX/YMAX need them
	},
	callbacks = {
		ROWVALUE_CB = true, ROW_ACTION_CB = true, ROW_PART_CB = true, ROW_ACTIVATE_CB = true,
		ROW_CONTEXT_CB = true, VALUECHANGED_CB = true, ROWBITS_CB = true, HEADER_CB = true,
	},
	create = function(ih, st)
		D(ih)
		FlatScrollbar.create(ih)
	end,
	natural = function(ih) return 240, rows_height(ih) * 5 end,
	place = function(ih, st) -- RESIZE_CB
		local d = D(ih)
		if d.measured_w ~= st.w or d.measured_h ~= st.h then
			d.measured_w, d.measured_h = st.w, st.h
			rows_refresh(ih)
		end
	end,
	draw = rows_redraw,
	event = rows_event,
	set = {
		COUNT = rows_set_count,
		VALUE = rows_set_value,
		HEADER = relayout("HEADER"), HEADERHEIGHT = relayout("HEADERHEIGHT"), ROWHEIGHT = relayout("ROWHEIGHT"),
		POSY = function(ih, st, value) st.attrs.POSY = value; return false end,
	},
	get = {
		COUNT = function(ih) return D(ih).count end,
		VALUE = function(ih) return D(ih).selected end,
		HOVER = function(ih) return D(ih).hover end,
		ACCESSIBLEVALUE = rows_get_accessible,
		VALUESTRING = rows_get_accessible,
	},
}

M._value = rows_value
return M
