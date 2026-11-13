--- IupFlatList, ported from iup_flatlist.c (Lunar's fork: patches 0003, 0005 and 0006).
--
-- The C control keeps its items in an array of { title, image, fg_color, bg_color, tip,
-- font, selected } and draws them with the flat drawing functions; so does this module.
-- Items are not element attributes: "1", "IMAGE2", "ITEMFGCOLOR3"... reach the item array
-- through the class's id setters and getters, as IUP's IDVALUE / IMAGE / ITEMFGCOLOR id
-- registrations do, and REMOVEITEM=ALL empties the array whatever wrote it.
--
-- The internal callbacks iFlatListCreateMethod installs (K_UP, K_DOWN, K_sUP, K_sDOWN,
-- K_cUP, K_cDOWN, K_ANY, K_PGUP, K_PGDN) are installed the same way, as the element's own
-- callbacks, so the runtime's IupKeyCallKeyCb propagation reaches them and an
-- application's K_ANY replaces the type-ahead, as on IUP.
--
-- With BORDER=YES (the canvas default) the control has WS_BORDER: a 1 px frame outside
-- the client area. Without FLATSCROLLBAR, SCROLLBAR (default YES) gives the native
-- Win32 bars (core.imgui.widgets.winscrollbar), shown while the view is smaller than
-- the content (YAUTOHIDE/XAUTOHIDE are always YES).
-- @module core.imgui.widgets.flatlist
local Classes = require("core.imgui.Classes")
local Element = require("core.imgui.Element")
local Fonts = require("core.imgui.Fonts")
local Color = require("core.imgui.Color")
local iup = require("core.imgui.iup")
local FlatScrollbar = require("core.imgui.widgets.flatscrollbar")
local FlatDraw = require("core.imgui.widgets.flatdraw")
local WinScroll = require("core.imgui.widgets.winscrollbar")

local floor, max, min = math.floor, math.max, math.min

local function attr(e, n) return Element.getAttribute(e, n) end
local function own(e, n) return Element.own(e, n) end
local yes = Element.isTrue -- iupStrBoolean
local function int(v, d) local n = tonumber(v); if not n then return d or 0 end; return floor(n) end

local RT
local function runtime()
	RT = RT or require("core.imgui.Runtime")
	return RT
end
--- IupUpdate / iupdrvRedrawNow
local function update(e) runtime().redraw(e) end

local DEFAULT, IGNORE, CLOSE, CONTINUE = -2, -1, -3, -4
if iup.DEFAULT then DEFAULT, IGNORE, CLOSE, CONTINUE = iup.DEFAULT, iup.IGNORE, iup.CLOSE, iup.CONTINUE end

-- Control data ---------------------------------------------------------------------------

--- ih->data: the item array and the aux fields.
local function data(st)
	local d = st.data
	if not d.items then
		d.items = {}
		d.line_height, d.line_width = 0, 0
		d.dragover_pos, d.dragged_pos = 0, 0
		d.has_focus, d.focus_pos = false, 0
		d.posx, d.posy = 0, 0
		d.xmax, d.ymax, d.dx, d.dy = 0, 0, 0, 0
		d.dirty = true
	end
	return d
end

local function changed(st) data(st).dirty = true end

-- Attribute-backed fields (the C setters only parse into ih->data) ----------------------

local function padding(e) return FlatDraw.intint(attr(e, "PADDING") or "2x2") end
local function spacing(e) return int(attr(e, "SPACING"), 0) end
local function icon_spacing(e) return int(attr(e, "ICONSPACING"), 2) end
local function img_position(e) return FlatDraw.imagePosition(attr(e, "IMAGEPOSITION")) end
local function border_width(e) return int(attr(e, "BORDERWIDTH"), 0) end
local function is_multiple(e) return yes(own(e, "MULTIPLE")) end
local function show_dragdrop(e) return yes(own(e, "SHOWDRAGDROP")) end
local function alignment(e) return FlatDraw.alignment(attr(e, "ALIGNMENT"), "ACENTER", "ACENTER") end

--- WS_BORDER: the canvas's native 1 px frame (BORDER, default YES).
local function native_border(e) return yes(attr(e, "BORDER")) and 1 or 0 end

--- iupFlatScrollBarGet: FLATSCROLLBAR says which flat bars exist.
local SB_NONE, SB_HORIZ, SB_VERT = 0, 1, 2
local function flat_sb(e)
	local v = tostring(attr(e, "FLATSCROLLBAR") or ""):upper()
	if v == "YES" then return SB_HORIZ + SB_VERT end
	if v == "HORIZONTAL" then return SB_HORIZ end
	if v == "VERTICAL" then return SB_VERT end
	return SB_NONE
end
--- iupBaseGetScrollbar
local function base_sb(e)
	local v = tostring(attr(e, "SCROLLBAR") or "YES"):upper()
	if v == "YES" then return SB_HORIZ + SB_VERT end
	if v == "HORIZONTAL" then return SB_HORIZ end
	if v == "VERTICAL" then return SB_VERT end
	return SB_NONE
end
local function has(sb, bit) return sb % (bit * 2) >= bit end

--- iFlatListGetScrollbar
local function get_scrollbar(e)
	local flat = flat_sb(e)
	if flat ~= SB_NONE then return flat end
	return base_sb(e)
end

--- iFlatListGetScrollbarSize
local function get_scrollbar_size(e)
	if flat_sb(e) ~= SB_NONE then
		if yes(attr(e, "SHOWFLOATING")) then return 0 end
		return int(attr(e, "SCROLLBARSIZE"), 15)
	end
	return WinScroll.SIZE -- iupdrvGetScrollbarSize
end

-- Items ------------------------------------------------------------------------------------

local function item_font(e, item)
	return Fonts.get(item.font or attr(e, "FONT"))
end

--- iupFlatDrawGetIconSize for one item, cached until the item, the font or the
-- spacing attributes change (the C measures again each time, with the same result).
local function item_size(e, item, hp, vp, pos, isp, fontkey)
	local key = fontkey .. "|" .. hp .. "|" .. vp .. "|" .. pos .. "|" .. isp
	if item._key ~= key then
		local font = item_font(e, item)
		item._w, item._h = FlatDraw.iconSize(e, pos, isp, hp, vp, item.image, item.title, font)
		item._key = key
	end
	return item._w, item._h
end

--- iFlatListCalcItemMaxSize
local function calc_item_max_size(e, items)
	local base_font = Fonts.get(attr(e, "FONT"))
	local _, max_h = base_font:charsize() -- iupdrvFontGetCharSize(ih, NULL, max_h)
	local max_w = 0
	local hp, vp = padding(e)
	local pos, isp = img_position(e), icon_spacing(e)
	local fontkey = tostring(attr(e, "FONT"))
	for i = 1, #items do
		local item = items[i]
		local w, h = item_size(e, item, hp, vp, pos, isp, fontkey .. "|" .. tostring(item.font))
		if w > max_w then max_w = w end
		if h > max_h then max_h = h end
	end
	return max_w, max_h
end

--- The canvas client area: the control without its WS_BORDER frame and native bars.
local function client(e, st)
	local nb = native_border(e)
	local d = data(st)
	local w, h = st.w - 2 * nb, st.h - 2 * nb
	if d.native_v then w = w - WinScroll.SIZE end
	if d.native_h then h = h - WinScroll.SIZE end
	return st.x + nb, st.y + nb, max(0, w), max(0, h)
end

--- iFlatListUpdateScrollBar, on the control's current size.
local function update_scrollbar(e, st)
	local d = data(st)
	local items = d.items
	local count = #items
	local canvas_width, canvas_height = st.w or 0, st.h or 0
	if yes(attr(e, "BORDER")) then -- native border around scrollbars
		canvas_width = canvas_width - 2
		canvas_height = canvas_height - 2
	end
	local bw = border_width(e)
	canvas_width = canvas_width - 2 * bw
	canvas_height = canvas_height - 2 * bw

	local max_w, max_h = calc_item_max_size(e, items)
	d.line_width = max(max_w, canvas_width)
	d.line_height = max_h
	local sp = spacing(e)

	local view_width = max_w
	local view_height = max_h * count + (count - 1) * sp
	if show_dragdrop(e) or yes(own(e, "DRAGDROPLIST")) then
		view_height = view_height + floor(d.line_height / 2) -- additional space for drop area
	end

	local sb = get_scrollbar(e)
	if sb ~= SB_NONE then
		local sb_size = get_scrollbar_size(e)
		local noscroll_width, noscroll_height = canvas_width, canvas_height
		if has(sb, SB_HORIZ) then
			d.xmax = view_width
			if view_height > noscroll_height then canvas_width = canvas_width - sb_size end
		else d.xmax = 0 end
		if has(sb, SB_VERT) then
			d.ymax = view_height
			if view_width > noscroll_width then canvas_height = canvas_height - sb_size end
		else d.ymax = 0 end
		-- check again, adding a scrollbar may affect the other scrollbar need if not done already
		if has(sb, SB_HORIZ) and view_height <= noscroll_height and view_height > canvas_height then
			canvas_width = canvas_width - sb_size
		end
		if has(sb, SB_VERT) and view_width <= noscroll_width and view_width > canvas_width then
			canvas_height = canvas_height - sb_size
		end
		if canvas_width < 0 then canvas_width = 0 end
		if canvas_height < 0 then canvas_height = 0 end
		d.dx = has(sb, SB_HORIZ) and canvas_width or 0
		d.dy = has(sb, SB_VERT) and canvas_height or 0
		d.liney = d.line_height + sp
		-- IupSetfAttribute(ih, "LINEY", ...): stored, the canvas's line step reads it
		Element.state(e).attrs.LINEY = tostring(d.liney)
	else
		d.xmax, d.ymax, d.dx, d.dy = 0, 0, 0, 0
	end
	-- the canvas's POSX/POSY stay inside the new range (iFlatScrollBarNormalizePos and
	-- the Win32 SetScrollInfo clamp)
	d.posy = max(0, min(d.posy or 0, max(0, d.ymax - d.dy)))
	d.posx = max(0, min(d.posx or 0, max(0, d.xmax - d.dx)))
	-- native bars: shown while the page is smaller than the range
	local native = flat_sb(e) == SB_NONE
	d.native_v = native and has(sb, SB_VERT) and d.ymax > d.dy or false
	d.native_h = native and has(sb, SB_HORIZ) and d.xmax > d.dx or false
	d.dirty = false
	d.size_w, d.size_h = st.w, st.h
end

local function ensure(e, st)
	local d = data(st)
	if d.dirty or d.size_w ~= st.w or d.size_h ~= st.h then update_scrollbar(e, st) end
	return d
end

--- After an item change: IUP updates the bars and redraws when mapped.
local function items_changed(e, st)
	changed(st)
	if (st.w or 0) > 0 then
		ensure(e, st)
		FlatScrollbar.sync(e)
	end
	update(e)
end

--- iFlatListConvertXYToPos (x, y in the client area)
local function convert_xy_to_pos(e, st, x, y)
	local d = ensure(e, st)
	local posy = d.posy
	local count = #d.items
	local step = d.line_height + spacing(e)
	if step <= 0 then return -1 end
	local pos = floor((y + posy) / step) + 1 -- pos starts at 1
	if y + posy < 0 or pos < 1 or pos > count then return -1 end
	return pos
end

local function copy_item(it)
	return { title = it.title, image = it.image, fg_color = it.fg_color, bg_color = it.bg_color,
		tip = it.tip, font = it.font, selected = false }
end

--- iFlatListCopyItem (from, to are 1-based; to may be count + 1)
local function copy_item_to(st, from, to)
	local items = data(st).items
	local copy = copy_item(items[from])
	if to <= #items then table.insert(items, to, copy) else items[#items + 1] = copy end
end

--- iFlatListRemoveItem (start is 0-based, as in C)
local function remove_items(st, start, remove_count)
	local items = data(st).items
	for _ = 1, remove_count do
		if items[start + 1] == nil then break end
		table.remove(items, start + 1)
	end
end

local function new_item(title) return { title = title, selected = false } end

-- Selection and the action callbacks ---------------------------------------------------------

local function get_id_value(st, pos)
	local items = data(st).items
	if pos < 1 or pos > #items then return nil end
	return items[pos].title
end

--- iFlatListCallActionCallback
local function call_action(e, st, pos, state)
	if pos < 1 or not Element.hasCallback(e, "FLAT_ACTION") then return end
	local text = get_id_value(st, pos)
	if Element.call(e, "FLAT_ACTION", text, pos, state) == CLOSE then runtime().exitLoop() end
end

--- iFlatListSingleCallActionCb
local function single_call_action(e, st, pos, old_pos)
	local unchanged = true
	if old_pos ~= -1 then
		if old_pos ~= pos then
			call_action(e, st, old_pos, 0)
			call_action(e, st, pos, 1)
			unchanged = false
		end
	else
		call_action(e, st, pos, 1)
		unchanged = false
	end
	if not unchanged then Element.call(e, "VALUECHANGED_CB") end
end

--- iFlatListMultipleCallActionCb
local function multiple_call_action(e, st, str)
	local unchanged = true
	if Element.hasCallback(e, "MULTISELECT_CB") then
		if Element.call(e, "MULTISELECT_CB", table.concat(str)) == CLOSE then runtime().exitLoop() end
	else
		-- must simulate the click on each item
		for i = 1, #str do
			if str[i] ~= "x" then
				call_action(e, st, i, str[i] == "+" and 1 or 0)
				unchanged = false
			end
		end
	end
	if not unchanged then Element.call(e, "VALUECHANGED_CB") end
end

--- iFlatListSelectItem
local function select_item(e, st, pos, ctrl, shift)
	local d = data(st)
	local items = d.items
	local count = #items
	if pos < 1 or pos > count then return end
	d.focus_pos = pos
	if is_multiple(e) then
		local last_pos = d.last_selected or 0
		local start, finish
		if pos <= last_pos then start, finish = pos, last_pos else start, finish = last_pos, pos end
		local str = {}
		for i = 1, count do str[i] = "x" end -- mark all as unchanged
		if not ctrl then
			for i = 1, count do -- un-select all
				if items[i].selected then str[i] = "-"; items[i].selected = false end
			end
		end
		if shift then
			for i = max(1, start), min(count, finish) do -- select interval
				if not items[i].selected then str[i] = "+"; items[i].selected = true end
			end
		elseif ctrl then
			if items[pos].selected then str[pos] = "-"; items[pos].selected = false -- toggle selection
			else str[pos] = "+"; items[pos].selected = true end
		elseif not items[pos].selected then
			str[pos] = "+"; items[pos].selected = true
		end
		if Element.hasCallback(e, "MULTISELECT_CB") or Element.hasCallback(e, "FLAT_ACTION") then
			multiple_call_action(e, st, str)
		end
	else
		local old_pos = -1
		for i = 1, count do
			if items[i].selected then items[i].selected = false; old_pos = i; break end
		end
		items[pos].selected = true
		if Element.hasCallback(e, "FLAT_ACTION") or Element.hasCallback(e, "VALUECHANGED_CB") then
			single_call_action(e, st, pos, old_pos)
		end
	end
	if not shift then d.last_selected = pos end
end

--- iFlatListCallDragDropCb (drag_id, drop_id 1-based on entry, as the button handler has them)
local function call_drag_drop(e, drag_id, drop_id, is_ctrl, is_shift)
	-- ignore a drop that will do nothing (the C compares 1-based drag with 1-based drop)
	if not is_ctrl and (drag_id + 1 == drop_id or drag_id == drop_id) then return DEFAULT end
	if is_ctrl and drag_id == drop_id then return DEFAULT end
	drag_id = drag_id + 1
	if drop_id < 0 then drop_id = -1 else drop_id = drop_id + 1 end
	if Element.hasCallback(e, "DRAGDROP_CB") then
		return Element.call(e, "DRAGDROP_CB", drag_id, drop_id, is_shift and 1 or 0, is_ctrl and 1 or 0)
	end
	return CONTINUE -- allow to move/copy by default if callback not defined
end

local function shift_key() return iup.GetGlobal("SHIFTKEY") == "ON" end

--- iFlatListScrollFocusVisible
local function scroll_focus_visible(e, st)
	local d = ensure(e, st)
	local sp = spacing(e)
	local focus_posy = (d.focus_pos - 1) * (d.line_height + sp)
	if focus_posy < d.posy then
		Element.setAttribute(e, "POSY", tostring(focus_posy))
	else
		local item_height = d.line_height + sp
		if focus_posy + item_height > d.posy + d.dy then
			Element.setAttribute(e, "POSY", tostring(focus_posy + item_height - d.dy))
		end
	end
end

-- Internal key callbacks (iFlatListCreateMethod) ------------------------------------------------

local function k_up(e)
	local st = Element.state(e)
	local d = data(st)
	if d.has_focus and d.focus_pos > 1 then
		select_item(e, st, d.focus_pos - 1, false, shift_key()) -- behave as no ctrl key pressed
		scroll_focus_visible(e, st)
		update(e)
	end
	return DEFAULT
end

local function k_down(e)
	local st = Element.state(e)
	local d = data(st)
	if d.has_focus and d.focus_pos < #d.items then
		select_item(e, st, d.focus_pos + 1, false, shift_key())
		scroll_focus_visible(e, st)
		update(e)
	end
	return DEFAULT
end

--- iFlatListFindNextItem
local function find_next_item(st, c)
	local d = data(st)
	local count = #d.items
	local start = d.focus_pos -- (focus_pos - 1) + 1, 0-based
	local finish = count
	if start == finish then finish, start = start - 1, 0 end
	c = string.char(c % 256):lower()
	for i = start, finish - 1 do
		local title = d.items[i + 1] and d.items[i + 1].title
		if title and title:sub(1, 1):lower() == c then return i + 1 end
	end
	return -1
end

local function k_any(e, c)
	local st = Element.state(e)
	local d = data(st)
	if d.has_focus and type(c) == "number" then
		local pos = find_next_item(st, c)
		if pos > 0 then
			select_item(e, st, pos, false, shift_key())
			scroll_focus_visible(e, st)
			update(e)
		end
	end
	return CONTINUE
end

local function k_pgup(e)
	local st = Element.state(e)
	local d = ensure(e, st)
	if d.has_focus then
		Element.setAttribute(e, "POSY", tostring(d.posy - d.dy))
		update(e)
	end
	return DEFAULT
end

local function k_pgdn(e)
	local st = Element.state(e)
	local d = ensure(e, st)
	if d.has_focus then
		Element.setAttribute(e, "POSY", tostring(d.posy + d.dy))
		update(e)
	end
	return DEFAULT
end

local INTERNAL_KEYS = {
	K_UP = k_up, K_DOWN = k_down, K_sUP = k_up, K_sDOWN = k_down, K_cUP = k_up, K_cDOWN = k_down,
	K_ANY = k_any, K_PGUP = k_pgup, K_PGDN = k_pgdn,
}

-- Natural size, placement, drawing -------------------------------------------------------------

--- iFlatListComputeNaturalSizeMethod
local function natural(e, st, L)
	local d = data(st)
	local w, h
	local back_image = own(e, "BACKIMAGE")
	local nb = yes(attr(e, "BORDER"))
	local bw = border_width(e)
	if yes(own(e, "FITTOBACKIMAGE")) and back_image then
		w, h = FlatDraw.imageInfo(back_image)
		w, h = w + 2 * bw, h + 2 * bw
		if nb then w, h = w + 2, h + 2 end
		return w, h
	end
	local count = #d.items
	local max_w, max_h = calc_item_max_size(e, d.items)
	local visiblecolumns = int(attr(e, "VISIBLECOLUMNS"), 0)
	local visiblelines = int(attr(e, "VISIBLELINES"), 0)
	local font = Fonts.get(attr(e, "FONT"))
	if visiblecolumns ~= 0 then
		w = FlatDraw.textSize(e, "WWWWWWWWWW", font)
		w = floor(visiblecolumns * w / 10)
	else
		w = max_w
	end
	local num_lines = visiblelines ~= 0 and visiblelines or count
	if max_h == 0 then local _, ch = font:charsize(); max_h = ch end
	h = max_h * num_lines + (num_lines - 1) * spacing(e)
	local sb = get_scrollbar(e)
	if sb ~= SB_NONE then
		local sb_size = get_scrollbar_size(e)
		if has(sb, SB_VERT) and visiblelines ~= 0 and visiblelines < count then w = w + sb_size end
		if has(sb, SB_HORIZ) and visiblecolumns ~= 0 and visiblecolumns < max_w then h = h + sb_size end
	end
	w, h = w + 2 * bw, h + 2 * bw
	if nb then w, h = w + 2, h + 2 end
	return w, h
end

local function place(e, st, L)
	update_scrollbar(e, st) -- RESIZE_CB
	FlatScrollbar.sync(e)   -- iupFlatScrollBarSetChildrenCurrentSize / Position
	local d = data(st)
	if d.native_v or d.native_h then
		local nb = native_border(e)
		local x, y = st.x + nb, st.y + nb
		local w, h = st.w - 2 * nb, st.h - 2 * nb
		local S = WinScroll.SIZE
		local vbar = d.native_v and { x = x + w - S, y = y, w = S, h = h - (d.native_h and S or 0), max = d.ymax, page = d.dy, pos = d.posy } or nil
		local hbar = d.native_h and { x = x, y = y + h - S, w = w - (d.native_v and S or 0), h = S, max = d.xmax, page = d.dx, pos = d.posx } or nil
		WinScroll.set(e, vbar, hbar)
	else
		WinScroll.set(e, nil, nil)
	end
end

--- The colour behind the list where a rounded body leaves its corners: the flat scroll
-- box it sits in, else iupDrawParentBackground.
local function behind_color(e)
	local p = Element.state(e).parent
	while p do
		local ps = Element.state(p)
		if not ps then break end
		if not FlatDraw.isVoid(ps) then
			if ps.classname == "flatscrollbox" then return attr(p, "BGCOLOR") end
			break
		end
		p = ps.parent
	end
	return FlatDraw.nativeParentBg(e)
end

--- iFlatListRedraw_CB
local function draw(e, st, dc, rt)
	local d = ensure(e, st)
	local ox, oy, width, height = client(e, st)
	if width <= 0 or height <= 0 then return end
	dc:clip_push(ox, oy, width, height)
	local items = d.items
	local count = #items
	local text_flags = FlatDraw.textFlags(e, "TABSTEXTALIGNMENT", "TABSTEXTWRAP", "TABSTEXTELLIPSIS")
	local foreground_color = attr(e, "FGCOLOR")
	local background_color = attr(e, "BGCOLOR")
	local posx, posy = d.posx, d.posy
	local back_image = own(e, "BACKIMAGE")
	local bw = border_width(e)
	local active = yes(attr(e, "ACTIVE") or "YES")
	local focus_feedback = yes(attr(e, "FOCUSFEEDBACK"))
	local make_inactive = not active
	local hp, vp = padding(e)
	local ha, va = alignment(e)
	local pos, isp = img_position(e), icon_spacing(e)
	local lw, lh, sp = d.line_width, d.line_height, spacing(e)

	local behind = behind_color(e)
	if behind then FlatDraw.fillRect(dc, ox, oy, 0, 0, width - 1, height - 1, Color.parse(behind)) end

	-- Lunar fork: CORNERRADIUS (rounded list body)
	FlatDraw.boxAttrib(e, dc, ox, oy, bw, width - bw - 1, bw, height - bw - 1, background_color, background_color, true)

	if back_image then
		if yes(own(e, "BACKIMAGEZOOM")) then
			FlatDraw.image(dc, ox, oy, back_image, false, background_color, bw, bw, width - bw, height - bw)
		else
			FlatDraw.image(dc, ox, oy, back_image, false, background_color, bw, bw)
		end
	end

	local x = -posx + bw
	local y0 = -posy + bw
	local step = lh + sp
	-- rows wholly above or below the client area draw nothing (the C clips them)
	local first = 1
	if step > 0 and y0 < 0 then first = max(1, floor(-y0 / step) + 1) end
	local item_radius = int(attr(e, "ITEMRADIUS"), 0)
	local ps_color, text_ps_color = attr(e, "PSCOLOR"), attr(e, "TEXTPSCOLOR")
	local marker_color = attr(e, "ITEMMARKERCOLOR")
	local hlcolor = attr(e, "HLCOLOR")
	local hl_alpha = int(attr(e, "HLCOLORALPHA"), 0) % 256
	local dragdrop = show_dragdrop(e)
	for i = first, count do
		local y = y0 + (i - 1) * step
		if y >= height then break end
		local item = items[i]
		local fgcolor = item.fg_color or foreground_color
		local bgcolor = item.bg_color or background_color
		if item.selected then
			if text_ps_color then fgcolor = text_ps_color end
			if ps_color then bgcolor = ps_color end
		end
		-- item background (Lunar fork: ITEMRADIUS draws a selected row as a rounded pill)
		if item.selected and item_radius > 0 then
			FlatDraw.box(dc, ox, oy, x, x + lw - 1, y, y + lh - 1, background_color, background_color, true)
			FlatDraw.gradientBox(dc, ox, oy, x + 4, x + lw - 5, y + 1, y + lh - 2, item_radius, bgcolor, nil, true, background_color, true)
		else
			FlatDraw.box(dc, ox, oy, x, x + lw - 1, y, y + lh - 1, bgcolor, bgcolor, true)
		end
		-- text and image
		FlatDraw.icon(e, dc, ox, oy, x, y, lw, lh, pos, isp, ha, va, hp, vp,
			item.image, make_inactive, item.title, text_flags, fgcolor, bgcolor, active, item_font(e, item))
		-- Lunar fork: ITEMMARKERCOLOR, the leading marker of the selected row
		if item.selected and marker_color then
			FlatDraw.fillRect(dc, ox, oy, x + 5, y + 5, x + 7, y + lh - 6, Color.parse(marker_color))
		end
		if item.selected or (dragdrop and d.dragover_pos == i) then
			local a = hl_alpha
			if a ~= 0 then
				if dragdrop and d.dragover_pos == i then a = floor(2 * a / 3) end
				local c = Color.parse(hlcolor)
				if c then FlatDraw.fillRect(dc, ox, oy, x, y, x + lw - 1, y + lh - 1, Color.alpha(c, a / 255)) end
			end
		end
		if d.has_focus and d.focus_pos == i and focus_feedback then
			FlatDraw.focusRect(dc, ox, oy, x, y, x + width - bw - 1, y + lh - 1)
		end
	end

	if bw > 0 then
		FlatDraw.borderAttrib(e, dc, ox, oy, 0, width - 1, 0, height - 1, bw, attr(e, "BORDERCOLOR"), background_color, active)
	end
	dc:clip_pop()
end

-- Events ----------------------------------------------------------------------------------------

local function set_pos_y(e, v)
	Element.setAttribute(e, "POSY", tostring(v))
end

--- The native bars' owner (winCanvasProcessVerScroll / HorScroll, then SCROLL_CB).
local function native_owner(e, st)
	local d = data(st)
	d.wsb_owner = d.wsb_owner or {
		range = function(el, vertical)
			local dd = ensure(el, Element.state(el))
			if vertical then return dd.ymax, dd.dy, dd.posy end
			return dd.xmax, dd.dx, dd.posx
		end,
		scroll = function(el, vertical, pos, op)
			Element.setAttribute(el, vertical and "POSY" or "POSX", tostring(floor(pos)))
			Element.call(el, "SCROLL_CB", op, data(Element.state(el)).posx, data(Element.state(el)).posy)
			update(el)
		end,
	}
	return d.wsb_owner
end

--- The native frame and bars, outside the client area.
local function draw_after(e, st, dc, rt)
	local d = data(st)
	if d.native_v or d.native_h then
		local wsb = d.wsb
		if wsb and wsb.v then wsb.v.max, wsb.v.page, wsb.v.pos = d.ymax, d.dy, d.posy end
		if wsb and wsb.h then wsb.h.max, wsb.h.page, wsb.h.pos = d.xmax, d.dx, d.posx end
		WinScroll.draw(e, st, dc)
		if rt then WinScroll.tick(e, native_owner(e, st), rt) end
	end
	if native_border(e) == 1 then
		dc:rect(st.x, st.y, st.w, st.h, "100 100 100", { thickness = 1 }) -- COLOR_WINDOWFRAME
	end
end

local function status_of(ev) return ev.status or iup._status(ev.mods or {}) end

--- iFlatListButton_CB (x, y in the client area)
local function button(e, st, ev, b, pressed, x, y, status)
	local d = data(st)
	local pos = convert_xy_to_pos(e, st, x, y)
	if Element.hasCallback(e, "FLAT_BUTTON_CB") then
		if Element.call(e, "FLAT_BUTTON_CB", ev.iupbutton or (48 + b), pressed and 1 or 0, x, y, status) == IGNORE then return end
	end
	local ctrl, shift = status:sub(2, 2) == "C", status:sub(1, 1) == "S"
	if b == 1 and not pressed and show_dragdrop(e) and d.dragged_pos > 0 then
		if pos == -1 then
			if y < 0 then pos = 1 else pos = #d.items + 1 end
		end
		if call_drag_drop(e, d.dragged_pos, pos, ctrl, shift) == CONTINUE then
			copy_item_to(st, d.dragged_pos, pos)
			select_item(e, st, pos, false, false) -- select the dropped item
			if not ctrl then
				if d.dragged_pos < pos then d.dragged_pos = d.dragged_pos - 1 end
				remove_items(st, d.dragged_pos, 1)
			end
		end
		d.dragover_pos, d.dragged_pos = 0, 0
		items_changed(e, st)
		return
	end
	if pos == -1 then return end
	if b == 1 and pressed then
		select_item(e, st, pos, ctrl, shift)
		if show_dragdrop(e) then d.dragged_pos = pos end
	end
	if pressed and ev.double then
		if Element.hasCallback(e, "DBLCLICK_CB") then
			local item = d.items[pos]
			if Element.call(e, "DBLCLICK_CB", pos, item and item.title) == IGNORE then return end
		end
	end
	update(e)
end

--- iFlatListMotion_CB
local function motion(e, st, x, y, status)
	local d = data(st)
	if Element.hasCallback(e, "FLAT_MOTION_CB") then
		if Element.call(e, "FLAT_MOTION_CB", x, y, status) == IGNORE then return end
	end
	local pos = convert_xy_to_pos(e, st, x, y)
	if pos == -1 then
		if d.item_tip then d.item_tip = nil; update(e) end -- iupFlatItemResetTip
		return
	end
	local tip = d.items[pos].tip
	if tip ~= d.item_tip then d.item_tip = tip end -- iupFlatItemSetTip / ResetTip
	if status:sub(3, 3) ~= "1" then return end -- iup_isbutton1
	-- button1 is pressed => dragging
	if is_multiple(e) and not show_dragdrop(e) then select_item(e, st, pos, false, true) end
	if y < 0 or y > st.h then
		-- scroll if dragging out of canvas
		set_pos_y(e, (pos - 1) * (d.line_height + spacing(e)))
	end
	if show_dragdrop(e) and d.dragged_pos > 0 then d.dragover_pos = pos end
	update(e)
end

local function event(e, st, ev, rt)
	local given = rt
	rt = setmetatable({}, { __index = function(_, k)
		local v = given and given[k]
		if v ~= nil then return v end
		return function() end
	end })
	local d = data(st)
	-- canvas coordinates: relative to the client area, inside the WS_BORDER frame
	local nb = native_border(e)
	local x = (ev.lx or ((ev.x or 0) - (st.x or 0))) - nb
	local y = (ev.ly or ((ev.y or 0) - (st.y or 0))) - nb
	if ev.type == "focus" or ev.type == "blur" then
		local focus = ev.type == "focus"
		if Element.hasCallback(e, "FLAT_FOCUS_CB") then
			if Element.call(e, "FLAT_FOCUS_CB", focus and 1 or 0) == IGNORE then return true end
		end
		d.has_focus = focus
		rt.redraw(e)
		return true
	elseif ev.type == "leave" then
		WinScroll.leave(e, rt)
		if Element.hasCallback(e, "FLAT_LEAVEWINDOW_CB") then
			if Element.call(e, "FLAT_LEAVEWINDOW_CB") == IGNORE then return true end
		end
		d.item_tip = nil
		return true
	elseif ev.type == "enter" then
		return true
	elseif ev.type == "wheel" then
		if Element.hasCallback(e, "WHEEL_CB") then
			Element.call(e, "WHEEL_CB", ev.dy or 0, x, y, status_of(ev))
			return true
		end
		if flat_sb(e) ~= SB_NONE then
			FlatScrollbar.on_wheel(e, ev.dy or 0) -- iFlatListWheel_CB: iupFlatScrollBarWheelUpdate
			rt.redraw(e)
			return true
		end
		-- winCanvasMsgProc WM_MOUSEWHEEL: SB_LINEUP/SB_LINEDOWN per notch with a vertical bar,
		-- else DefWindowProc passes it to the parent
		if has(base_sb(e), SB_VERT) then
			local owner = native_owner(e, st)
			local notches = math.abs(ev.dy or 0)
			for _ = 1, max(1, floor(notches)) do
				WinScroll.process(e, owner, true, (ev.dy or 0) > 0 and "lineup" or "linedown")
			end
			return true
		end
		return false
	elseif ev.type == "press" or ev.type == "release" then
		local pressed = ev.type == "press"
		if d.native_v or d.native_h then
			local owner = native_owner(e, st)
			if pressed and ev.button == 1 and WinScroll.press(e, owner, ev.x or 0, ev.y or 0, rt) then return true end
			if not pressed and ev.button == 1 and WinScroll.release(e, owner, ev.x or 0, ev.y or 0, rt) then return true end
		end
		-- winCanvasMsgProc: focus on click when CANFOCUS, and the mouse captured
		if pressed then
			if yes(attr(e, "CANFOCUS") or "YES") then rt.setFocus(e) end
			rt.capture(e)
		else
			rt.release()
		end
		button(e, st, ev, ev.button or 1, pressed, x, y, status_of(ev))
		return true
	elseif ev.type == "move" then
		if (d.native_v or d.native_h) and WinScroll.move(e, native_owner(e, st), ev.x or 0, ev.y or 0, rt) then return true end
		motion(e, st, x, y, status_of(ev))
		return true
	end
	return false
end

-- Attributes ------------------------------------------------------------------------------------

--- iFlatListSetValueAttrib
local function set_value(e, st, value)
	local d = data(st)
	local items = d.items
	local count = #items
	if value == nil then
		for i = 1, count do items[i].selected = false end -- un-select all
		-- Lunar fork: keep the keyboard focus row inside the list, which may have just shrunk
		if d.focus_pos > count then d.focus_pos = count end
	elseif is_multiple(e) then
		if #value ~= count then return end
		for i = 1, count do
			local c = value:sub(i, i)
			if c == "+" then items[i].selected = true; d.last_selected = i - 1
			elseif c == "-" then items[i].selected = false end
		end
	else
		local pos = tonumber(value)
		if pos and pos == floor(pos) and pos > 0 and pos <= count then
			for i = 1, count do
				if items[i].selected then items[i].selected = false; break end
			end
			items[pos].selected = true
			d.last_selected = pos
			-- Lunar fork: keyboard navigation starts from the selected item, and the list
			-- scrolls to it, as in a native list.
			d.focus_pos = pos
			if (st.w or 0) > 0 then scroll_focus_visible(e, st) end
		end
	end
	update(e)
end

local function get_value(e, st)
	local items = data(st).items
	if is_multiple(e) then
		local out = {}
		for i = 1, #items do out[i] = items[i].selected and "+" or "-" end
		return table.concat(out)
	end
	for i = 1, #items do if items[i].selected then return tostring(i) end end
	return nil
end

--- iFlatListSetIdValueAttrib
local function set_id_value(e, st, pos, value)
	local items = data(st).items
	local count = #items
	if pos < 1 then return end
	if value == nil then -- remove remaining items
		if pos <= count then remove_items(st, pos - 1, count - (pos - 1)) end
	elseif pos <= count then -- change an existing item
		items[pos].title = value
		items[pos]._key = nil
	else -- add a new item (iupArrayInsert fills the gap with empty items)
		for i = count + 1, pos - 1 do items[i] = new_item(nil) end
		items[pos] = new_item(value)
	end
	items_changed(e, st)
end

local function item_field_setter(field, layout)
	return function(e, st, pos, value)
		local items = data(st).items
		if pos < 1 or pos > #items then return end
		items[pos][field] = value
		items[pos]._key = nil
		if layout then items_changed(e, st) else update(e) end
	end
end

local function item_field_getter(field)
	return function(e, st, pos)
		local items = data(st).items
		if pos < 1 or pos > #items then return nil end
		return items[pos][field]
	end
end

local function font_info(font)
	-- iupGetFontInfo: "Face, Style Size"
	local face, rest = tostring(font or ""):match("^([^,]*),%s*(.*)$")
	if not face then return nil end
	local size = tonumber(rest:match("(-?%d+)%s*$"))
	if not size then return nil end
	local style = rest:gsub("(-?%d+)%s*$", "")
	return face, style, size
end

local ID_SET = {
	IMAGE = function(e, st, pos, value, handle)
		item_field_setter("image", true)(e, st, pos, handle or value)
	end,
	ITEMFGCOLOR = item_field_setter("fg_color"),
	ITEMBGCOLOR = item_field_setter("bg_color"),
	ITEMTIP = item_field_setter("tip"),
	ITEMFONT = item_field_setter("font", true),
	--- iFlatListSetItemFontStyleAttrib
	ITEMFONTSTYLE = function(e, st, pos, value)
		local items = data(st).items
		if not value or pos < 1 or pos > #items then return end
		local face, _, size = font_info(items[pos].font or attr(e, "FONT"))
		if not face then return end
		Element.setAttribute(e, "ITEMFONT" .. pos, string.format("%s, %s %d", face, value, size))
	end,
	--- iFlatListSetItemFontSizeAttrib (the C passes the style words as the size: the size
	-- printed is the first of them, "%d" of a string pointer; the face and value are kept
	-- here, as the intent is plain)
	ITEMFONTSIZE = function(e, st, pos, value)
		local items = data(st).items
		if not value or pos < 1 or pos > #items then return end
		local face, style = font_info(items[pos].font or attr(e, "FONT"))
		if not face then return end
		Element.setAttribute(e, "ITEMFONT" .. pos, string.format("%s, %s%s", face, style, value))
	end,
	--- iFlatListSetInsertItemAttrib
	INSERTITEM = function(e, st, pos, value)
		local items = data(st).items
		if pos < 1 or pos > #items then return end
		if value then table.insert(items, pos, new_item(value)) end
		items_changed(e, st)
	end,
}

local ID_GET = {
	IMAGE = function(e, st, pos)
		local v = item_field_getter("image")(e, st, pos)
		if Element.is(v) then return Element.getName and Element.getName(v) or Element.autoName(v) end
		return v
	end,
	ITEMFGCOLOR = item_field_getter("fg_color"),
	ITEMBGCOLOR = item_field_getter("bg_color"),
	ITEMTIP = item_field_getter("tip"),
	ITEMFONT = item_field_getter("font"),
	ITEMFONTSTYLE = function(e, st, pos)
		local items = data(st).items
		if pos < 1 or pos > #items then return nil end
		local face, style = font_info(items[pos].font or attr(e, "FONT"))
		if not face then return nil end
		local out = {}
		for _, w in ipairs({ "Bold", "Italic", "Underline", "Strikeout" }) do
			if style:find(w) then out[#out + 1] = w .. " " end
		end
		return table.concat(out)
	end,
	ITEMFONTSIZE = function(e, st, pos)
		local items = data(st).items
		if pos < 1 or pos > #items then return nil end
		local _, _, size = font_info(items[pos].font or attr(e, "FONT"))
		return size and tostring(size)
	end,
}

local function posy_setter(e, st, v)
	local d = ensure(e, st)
	local n = tonumber(v) or 0
	d.posy = floor(max(0, min(n, max(0, d.ymax - d.dy))))
	FlatScrollbar.sync(e)
	update(e)
	return false
end

local function posx_setter(e, st, v)
	local d = ensure(e, st)
	local n = tonumber(v) or 0
	d.posx = floor(max(0, min(n, max(0, d.xmax - d.dx))))
	FlatScrollbar.sync(e)
	update(e)
	return false
end

local function redraw_setter(e, st) changed(st); update(e) end -- iFlatListSetAttribPostRedraw (stores)
local function layout_setter(e, st) changed(st); update(e) end

local def = {
	name = "flatlist", children = 0, clip = true, focusable = true,
	visibleChildren = FlatScrollbar.visible_children,
	natural = natural, place = place, draw = draw, drawAfter = draw_after, event = event,
	--- IupConvertXYToPos: dialog client coordinates in, the 1-based item or -1
	xyToPos = function(e, st, x, y) return convert_xy_to_pos(e, st, x, y) end,
	create = function(e)
		local st = Element.state(e)
		data(st)
		FlatScrollbar.create(e)
		for name, fn in pairs(INTERNAL_KEYS) do
			if st.cbs[name] == nil then st.cbs[name] = fn end
		end
	end,
	defaults = {
		FGCOLOR = function() return Element.globals.DLGFGCOLOR end,
		BGCOLOR = function() return Element.globals.DLGBGCOLOR end,
		HLCOLOR = "TXTHLCOLOR", FOCUSFEEDBACK = "YES", PADDING = "2x2", VISIBLELINES = "5",
		SCROLLBARSIZE = "15", ITEMRADIUS = "0", HLCOLORALPHA = "128", SCROLLBAR = "YES",
		ICONSPACING = "2", IMAGEPOSITION = "LEFT", SPACING = "0", BORDERWIDTH = "0",
		ALIGNMENT = "ALEFT:ACENTER", TEXTALIGNMENT = "ALEFT",
	},
	get = {
		COUNT = function(e, st) return tostring(#data(st).items) end,
		VALUE = function(e, st) return get_value(e, st) end,
		VALUESTRING = function(e, st)
			if is_multiple(e) then return nil end
			return get_id_value(st, tonumber(get_value(e, st)) or 0)
		end,
		HASFOCUS = function(e, st) return data(st).has_focus and "YES" or "NO" end,
		MULTIPLE = function(e, st) return is_multiple(e) and "YES" or "NO" end,
		POSY = function(e, st) return tostring(ensure(e, st).posy) end,
		POSX = function(e, st) return tostring(ensure(e, st).posx) end,
		YMAX = function(e, st) return tostring(ensure(e, st).ymax) end,
		XMAX = function(e, st) return tostring(ensure(e, st).xmax) end,
		DY = function(e, st) return tostring(ensure(e, st).dy) end,
		DX = function(e, st) return tostring(ensure(e, st).dx) end,
		LINEY = function(e, st) local d = ensure(e, st); return d.liney and tostring(d.liney) or nil end,
		TIP = function(e, st) return data(st).item_tip end,
	},
	set = {
		VALUE = function(e, st, v) set_value(e, st, v); return false end,
		--- iFlatListSetValueStringAttrib
		VALUESTRING = function(e, st, v)
			if is_multiple(e) then return false end
			local items = data(st).items
			for i = 1, #items do
				if items[i].title == v then set_value(e, st, tostring(i)); return false end
			end
			return false
		end,
		POSY = posy_setter,
		POSX = posx_setter,
		--- iFlatListSetAppendItemAttrib
		APPENDITEM = function(e, st, v)
			if v then local items = data(st).items; items[#items + 1] = new_item(v) end
			items_changed(e, st)
			return false
		end,
		--- iFlatListSetRemoveItemAttrib
		REMOVEITEM = function(e, st, v)
			local items = data(st).items
			if v == nil or tostring(v):upper() == "ALL" then
				remove_items(st, 0, #items)
			else
				local pos = tonumber(v)
				if pos then remove_items(st, pos - 1, 1) end
			end
			items_changed(e, st)
			return false
		end,
		--- iFlatListSetTopItemAttrib
		TOPITEM = function(e, st, v)
			local pos = tonumber(v)
			if pos then
				local d = ensure(e, st)
				if pos < 1 or pos > #d.items then return false end
				Element.setAttribute(e, "POSY", tostring((pos - 1) * (d.line_height + spacing(e))))
				update(e)
			end
			return false
		end,
		--- iFlatListSetFlatScrollbarAttrib
		FLATSCROLLBAR = function(e, st, v)
			if v and tostring(v):upper() ~= "NO" then
				Element.setAttribute(e, "SCROLLBAR", "NO")
			end
			changed(st)
		end,
		--- iFlatListSetMultipleAttrib / SetShowDragDropAttrib: valid only before map
		MULTIPLE = function(e, st) if st.mapped_list then return false end end,
		PADDING = layout_setter, SPACING = layout_setter, ICONSPACING = layout_setter,
		IMAGEPOSITION = layout_setter, BORDERWIDTH = layout_setter, FONT = layout_setter,
		FGCOLOR = redraw_setter, BGCOLOR = redraw_setter, CORNERRADIUS = redraw_setter,
		ITEMRADIUS = redraw_setter, ALIGNMENT = redraw_setter,
		SHOWDRAGDROP = layout_setter, DRAGDROPLIST = layout_setter,
	},
	callbacks = {
		FLAT_ACTION = true, VALUECHANGED_CB = true, DBLCLICK_CB = true, MULTISELECT_CB = true,
		FLAT_BUTTON_CB = true, FLAT_MOTION_CB = true, FLAT_FOCUS_CB = true, FLAT_LEAVEWINDOW_CB = true,
		DRAGDROP_CB = true,
	},
}

-- Id attributes: "<n>" (IDVALUE), IMAGE<n>, ITEMFGCOLOR<n>... and INSERTITEM<n>.
local function id_name(name)
	name = tostring(name)
	local n = name:match("^(%d+)$")
	if n then return "", tonumber(n) end
	local base, id = name:match("^([A-Z]+)(%d+)$")
	if base then return base, tonumber(id) end
	base, id = name:match("^(IDVALUE)(%d+)$")
	if base then return "", tonumber(id) end
	return nil
end

setmetatable(def.set, { __index = function(_, name)
	local base, id = id_name(name)
	if base == "" then
		return function(e, st, value) set_id_value(e, st, id, value); return false end
	end
	local fn = base and ID_SET[base]
	if fn then
		return function(e, st, value, handle) fn(e, st, id, value, handle); return false end
	end
	return nil
end })

setmetatable(def.get, { __index = function(_, name)
	local base, id = id_name(name)
	if base == "" then
		return function(e, st) return get_id_value(st, id) end
	end
	local fn = base and ID_GET[base]
	if fn then return function(e, st) return fn(e, st, id) end end
	return nil
end })

Classes.define(def)
return Classes
