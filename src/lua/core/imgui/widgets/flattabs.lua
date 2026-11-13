-- IUP FlatTabs, rendered by the ImGui draw context.
-- @module core.imgui.widgets.flattabs
local Classes = require("core.imgui.Classes")
local Element = require("core.imgui.Element")
local Fonts = require("core.imgui.Fonts")
local Draw = require("core.imgui.Draw")
local Layout = require("core.imgui.Layout")
local iup = require("core.imgui.iup")
local motion = require("core.imgui.motion")
local PageTransitions = require("core.lib.PageTransitions")
local Color = require("core.imgui.Color")

local M = {}
local CLOSE_SIZE, CLOSE_GAP, CLOSE_BORDER = 13, 12, 8

local function attr(el, name) return Element.getAttribute(el, name) end
local function own(el, name) return Element.own(el, name) end
local yes = Element.isTrue -- iupStrBoolean
local function integer(v, default)
	local n = tonumber(v)
	return n and math.floor(n) or default
end
local function pair(v, dx, dy)
	local a, b = tostring(v or ""):match("^%s*(-?%d+)%s*[xX]%s*(-?%d+)%s*$")
	return tonumber(a) or dx, tonumber(b) or dy
end
local function typeOf(el)
	local t = tostring(attr(el, "TABTYPE") or "TOP"):upper()
	return (t == "BOTTOM" or t == "LEFT" or t == "RIGHT") and t or "TOP"
end
local function horizontal(el)
	local t = typeOf(el)
	return t == "TOP" or t == "BOTTOM"
end
local function visibleAt(el, pos)
	return attr(el, "TABVISIBLE" .. pos) ~= "NO" and attr(el, "TABVISIBLE" .. pos) ~= "0"
end
local function activeAt(el, pos)
	return attr(el, "TABACTIVE" .. pos) ~= "NO" and attr(el, "TABACTIVE" .. pos) ~= "0"
end
local function pages(el)
	return Element.state(el).children
end
local function indexed(el, name, pos, child)
	return own(el, name .. pos) or (child and own(child, name)) or attr(child, name)
end
local function tabTitle(el, pos, child)
	return indexed(el, "TABTITLE", pos, child) or tostring(pos)
end
local function tabImage(el, pos, child)
	return Draw.resolveImage(indexed(el, "TABIMAGE", pos, child))
end
local function tabFont(el, pos)
	return Fonts.get(indexed(el, "TABFONT", pos) or attr(el, "TABSFONT") or attr(el, "FONT"))
end
local function current(el)
	local d = Element.state(el).data
	local c = d.current
	if c and Element.state(c) then return c end
	return nil
end
local function currentPos(el)
	local c = current(el)
	if not c then return -1 end
	return Element.childPos(el, c)
end
local function setCurrent(el, child, notify)
	local st = Element.state(el)
	local old = st.data.current
	if old == child then return iup.DEFAULT end
	local oldpos = old and Element.childPos(el, old) or -1
	local newpos = child and Element.childPos(el, child) or -1
	if notify and child then
		local ret
		if Element.hasCallback(el, "TABCHANGE_CB") then
			ret = Element.call(el, "TABCHANGE_CB", child, old)
		elseif Element.hasCallback(el, "TABCHANGEPOS_CB") then
			ret = Element.call(el, "TABCHANGEPOS_CB", newpos, oldpos)
		end
		if ret ~= nil and ret ~= iup.DEFAULT then return ret end
	end
	st.data.current = child
	st.handles.VALUE_HANDLE = child
	st.handles.VALUE = child
	if old then Element.setAttribute(old, "VISIBLE", "NO") end
	if child then Element.setAttribute(child, "VISIBLE", "YES") end
	M.beginPageTransition(el, st, old, child, newpos > oldpos)
	return iup.DEFAULT
end

-- Page transitions, drawn live (core.lib.PageTransitions): the strip paints the leaving
-- page and the arriving one, moved and faded by the kind, for the transition's length;
-- the switch itself (VALUE, callbacks, hit testing) has already happened. Only on a strip
-- that shows its tabs, that was on screen the frame before (nothing animates into place
-- as a dialog first appears), and without PAGETRANSITION=NO.
function M.beginPageTransition(el, st, from, to, forward)
	st.data.page_tr = nil
	if not (from and to) or not yes(attr(el, "SHOWTABS")) then return end
	if tostring(attr(el, "PAGETRANSITION") or "YES"):upper() == "NO" then return end
	local R = package.loaded["core.imgui.Runtime"]
	if not (R and R.frameNo and st.data.painted_frame and st.data.painted_frame >= R.frameNo() - 1) then return end
	local def, spec, name = motion.pageTransition()
	if not def or name == "none" or not def.frame then return end
	local ease, dur = motion.timing(spec)
	if dur <= 0 then return end
	st.data.page_tr = { from = from, to = to, forward = forward, def = def, spec = spec,
		ease = ease, dur = dur, t0 = motion.now(), name = name }
	motion.keepGoing()
end

--- The page transition running on a strip, or nil: `{ from, to, name, progress }`.
function M.pageTransition(el)
	local st = Element.state(el)
	local tr = st and st.data.page_tr
	if not tr then return nil end
	return { from = tr.from, to = tr.to, name = tr.name, progress = math.min(1, (motion.now() - tr.t0) / tr.dur) }
end

local function round(v) return v >= 0 and math.floor(v + 0.5) or -math.floor(-v + 0.5) end
local function firstVisible(el, start, direction)
	local ps = pages(el)
	local i = start or 1
	while i >= 1 and i <= #ps do
		if visibleAt(el, i - 1) and activeAt(el, i - 1) then return ps[i] end
		i = i + direction
	end
end
local function ensureCurrent(el)
	local c = current(el)
	if c and Element.childPos(el, c) >= 0 and visibleAt(el, Element.childPos(el, c)) then return c end
	local pos = c and Element.childPos(el, c) or 0
	if pos < 0 then pos = 0 end
	return firstVisible(el, pos + 1, 1) or firstVisible(el, pos, -1)
end
local function fireResult(ev, result)
	if result == iup.CLOSE then ev.result = result end
	return result
end

local function tabSize(el, pos, child)
	local title = tabTitle(el, pos, child)
	local image = tabImage(el, pos, child)
	local font = tabFont(el, pos)
	local tw, th = font:measure(title)
	local iw, ih = Draw.imageSize(image)
	local spacing = integer(attr(el, "TABSIMAGESPACING"), 2)
	local px, py = pair(attr(el, "TABSPADDING"), 6, 4)
	local has_image = image ~= nil
	local w, h = tw, th
	if has_image then
		w, h = tw + iw + spacing, math.max(th, ih)
	end
	if yes(attr(el, "SHOWCLOSE")) then
		w = w + CLOSE_GAP + CLOSE_SIZE + CLOSE_BORDER
	end
	return w + px * 2, h + py * 2
end
local function metrics(el)
	local ps = pages(el)
	local t = typeOf(el)
	local px, py = pair(attr(el, "TABSPADDING"), 6, 4)
	-- patch 0004: a strip with SHOWTABS=NO has no title band at all
	if not yes(attr(el, "SHOWTABS")) then return 0, 0, px, py end
	local bw, bh, total = 0, 0, 0
	for i, child in ipairs(ps) do
		if visibleAt(el, i - 1) and attr(child, "FLOATING") ~= "YES" then
			local w, h = tabSize(el, i - 1, child)
			if horizontal(el) then
				total = total + w
				bh = math.max(bh, h)
			else
				total = total + h
				bw = math.max(bw, w)
			end
		end
	end
	if #ps == 0 then
		local w, h = tabSize(el, 0, nil)
		bw, bh, total = w, h, horizontal(el) and w or h
	end
	if horizontal(el) then bw = total else bh = total end
	if not horizontal(el) then bw = integer(attr(el, "TABSBREADTH"), bw) end
	return bw, bh, px, py
end
local function clientRect(el, st)
	local bw, bh = metrics(el)
	local x, y, w, h = st.x, st.y, st.w, st.h
	local t = typeOf(el)
	if t == "TOP" then y, h = y + bh, h - bh
	elseif t == "BOTTOM" then h = h - bh
	elseif t == "LEFT" then x, w = x + bw, w - bw
	else w = w - bw end
	local lines = yes(attr(el, "SHOWLINES"))
	if lines then
		if horizontal(el) then x, y, w, h = x + 1, y + 1, w - 2, h - 1
		else x, y, w, h = x + 1, y + 1, w - 1, h - 2 end
	end
	return x, y, math.max(0, w), math.max(0, h)
end
local function tabRect(el, st, pos, offset)
	local bw, bh = metrics(el)
	local t = typeOf(el)
	local x, y = st.x, st.y
	local tabw, tabh = tabSize(el, pos, pages(el)[pos + 1])
	if t == "TOP" or t == "BOTTOM" then
		x = x + (offset or 0)
		y = t == "BOTTOM" and st.y + st.h - bh or st.y
		return x, y, tabw, bh
	end
	y = y + (offset or 0)
	x = t == "RIGHT" and st.x + st.w - bw or st.x
	return x, y, bw, tabh
end
local function extraSize(el, id)
	local title = attr(el, "EXTRATITLE" .. id) or ""
	local image = Draw.resolveImage(attr(el, "EXTRAIMAGE" .. id))
	local font = Fonts.get(attr(el, "EXTRAFONT" .. id) or attr(el, "TABSFONT") or attr(el, "FONT"))
	local tw, th = font:measure(title)
	local iw, ih = Draw.imageSize(image)
	local px, py = pair(attr(el, "TABSPADDING"), 6, 4)
	local spacing = integer(attr(el, "TABSIMAGESPACING"), 2)
	local w = math.max(tw, iw)
	local h = math.max(th, ih)
	if image and title then w = iw + spacing + tw end
	return w + px * 2, h + py * 2
end
local function extraRect(el, st, id, used)
	local bw, bh = metrics(el)
	local ew, eh = extraSize(el, id)
	local t = typeOf(el)
	if horizontal(el) then
		return st.x + st.w - used - ew, t == "BOTTOM" and st.y + st.h - bh or st.y, ew, bh
	end
	return t == "RIGHT" and st.x + st.w - bw or st.x, st.y + st.h - used - eh, bw, eh
end
local function hitExtra(el, st, x, y)
	if not yes(attr(el, "SHOWTABS")) then return nil end
	local count = integer(attr(el, "EXTRABUTTONS"), 0)
	local used = 0
	for id = 1, count do
		local ew, eh = extraSize(el, id)
		local tx, ty, tw, th = extraRect(el, st, id, used)
		if x >= tx and x < tx + tw and y >= ty and y < ty + th then return id end
		used = used + (horizontal(el) and ew or eh)
	end
end
local function hitTab(el, st, x, y)
	if not yes(attr(el, "SHOWTABS")) then return nil end
	local offset = 0
	for i, child in ipairs(pages(el)) do
		if visibleAt(el, i - 1) then
			local tx, ty, tw, th = tabRect(el, st, i - 1, offset)
			if x >= tx and x < tx + tw and y >= ty and y < ty + th then
				local close = false
				if yes(attr(el, "SHOWCLOSE")) then
					if horizontal(el) then close = x >= tx + tw - CLOSE_GAP - CLOSE_SIZE - CLOSE_BORDER
					else close = y >= ty + th - CLOSE_GAP - CLOSE_SIZE - CLOSE_BORDER end
				end
				return i - 1, close, tx, ty, tw, th
			end
			offset = offset + (horizontal(el) and tw or th)
		end
	end
	return nil
end
-- iFlatTabsConvertXYToPos: the tab under (x, y) inside the strip, or -1 (TabOrder and
-- TabStripView find the tab a press or a drag is over with it)
local function xyToPos(el, st, x, y)
	local hit = hitTab(el, st, st.x + x, st.y + y)
	return hit or -1
end
local function drawTabContent(el, st, dc, pos, x, y, w, h, color)
	local child = pages(el)[pos + 1]
	local title = tabTitle(el, pos, child)
	local image = tabImage(el, pos, child)
	if image and yes(attr(el, "TABSHIDETITLE")) then title = nil end
	local font = tabFont(el, pos)
	local px, py = pair(attr(el, "TABSPADDING"), 6, 4)
	local iw, ih = Draw.imageSize(image)
	local spacing = integer(attr(el, "TABSIMAGESPACING"), 2)
	local image_position = tostring(attr(el, "TABSIMAGEPOSITION") or "LEFT"):upper()
	local tw = title and font:measure(title) or 0
	if image then
		local ix, iy = x + px, y + (h - ih) / 2
		if image_position == "RIGHT" and title then ix = x + w - px - iw
		elseif image_position == "CENTER" then ix = x + (w - iw) / 2
		end
		dc:image(image, ix, iy, iw, ih, { inactive = not activeAt(el, pos) })
		if title then
			local tx = image_position == "RIGHT" and x + px or ix + iw + spacing
			dc:text(title, tx, y + py, math.max(0, w - (tx - x) - px), h - py * 2, color, font,
				{ align = attr(el, "TABSTEXTALIGNMENT") or "ALEFT", valign = "center", ellipsis = true })
		end
	elseif title then
		dc:text(title, x + px, y + py, math.max(0, w - px * 2), h - py * 2, color, font,
			{ align = attr(el, "TABSTEXTALIGNMENT") or "ALEFT", valign = "center", ellipsis = true })
	end
end

local function draw(el, st, dc)
	local R = package.loaded["core.imgui.Runtime"]
	st.data.painted_frame = R and R.frameNo and R.frameNo() or nil
	local bg = attr(el, "BGCOLOR")
	if bg then dc:fill(st.x, st.y, st.w, st.h, bg, { radius = integer(attr(el, "CORNERRADIUS"), 0) }) end
	if not yes(attr(el, "SHOWTABS")) then
		if yes(attr(el, "SHOWLINES")) then dc:rect(st.x, st.y, st.w, st.h, attr(el, "TABSLINECOLOR"), {}) end
		return
	end
	local bw, bh = metrics(el)
	local t = typeOf(el)
	local stripx, stripy, stripw, striph = st.x, st.y, st.w, st.h
	if t == "TOP" then striph = bh elseif t == "BOTTOM" then stripy = st.y + st.h - bh; striph = bh
	elseif t == "LEFT" then stripw = bw elseif t == "RIGHT" then stripx = st.x + st.w - bw; stripw = bw end
	dc:fill(stripx, stripy, stripw, striph, attr(el, "TABSBACKCOLOR") or bg)
	local current_child = current(el)
	local offset = 0
	-- Motion (core.imgui.motion): a tab's colours ease to their new state, at the
	-- hover token when the pointer caused it and at the selection token when the
	-- selection did; the selected tab's line is one indicator that slides there.
	local was_selected = st.data.was_selected
	if not was_selected then was_selected = setmetatable({}, { __mode = "k" }); st.data.was_selected = was_selected end
	local indicator
	for i, child in ipairs(pages(el)) do
		if visibleAt(el, i - 1) then
			local x, y, w, h = tabRect(el, st, i - 1, offset)
			local selected = child == current_child
			local hovered = st.data.hover == i - 1
			local cid = Element.state(child) and Element.state(child).id or i
			local role = (was_selected[child] ~= nil and was_selected[child] ~= selected) and "tab_select" or "hover"
			was_selected[child] = selected
			-- iFlatTabsRedraw_CB: the current tab in BGCOLOR/FORECOLOR (TABSSELCOLOR on side
			-- strips only); the others in TABBACKCOLORn/TABSFORECOLOR, HIGHCOLOR on hover.
			local color, fill
			if selected then
				fill = (t == "LEFT" and Element.own(el, "TABSSELCOLOR")) or attr(el, "BGCOLOR")
				color = attr(el, "FORECOLOR")
			else
				fill = indexed(el, "TABBACKCOLOR", i - 1, child)
				color = Element.own(el, "TABFORECOLOR" .. (i - 1)) or attr(el, "TABSFORECOLOR")
				if hovered then
					color = attr(el, "HIGHCOLOR") or attr(el, "FORECOLOR")
					fill = Element.own(el, "TABHIGHCOLOR" .. (i - 1)) or attr(el, "TABSHIGHCOLOR") or fill
				end
			end
			fill = motion.color(st, "fill" .. cid, fill, role)
			color = motion.color(st, "fg" .. cid, color or attr(el, "FGCOLOR"), role)
			if fill then
				local radius = integer(attr(el, "CORNERRADIUS"), 0)
				if t == "LEFT" then
					dc:fill(x + 6, y + 1, math.max(0, w - 12), math.max(0, h - 3), fill, { radius = radius })
				elseif t == "TOP" and radius > 0 and h > 2 * radius then
					dc:fill(x, y, w, h, fill, { radius = radius })
					dc:fill(x, y + radius, w, h - radius, fill)
				else
					dc:fill(x, y, w, h, fill)
				end
			end
			drawTabContent(el, st, dc, i - 1, x, y, w, h, color or attr(el, "FGCOLOR"))
			if selected and attr(el, "TABSACTIVELINE") then indicator = { x, y, w, h, child } end
			if yes(attr(el, "SHOWCLOSE")) then
				local cx, cy = x + w - CLOSE_GAP - CLOSE_SIZE, y + (h - CLOSE_SIZE) / 2
				if not horizontal(el) then cx, cy = x + (w - CLOSE_SIZE) / 2, y + h - CLOSE_GAP - CLOSE_SIZE end
				local close = Draw.resolveImage(indexed(el, "CLOSEIMAGE", i - 1, child) or attr(el, "CLOSEIMAGE"))
				if close then
					dc:image(close, cx, cy, CLOSE_SIZE, CLOSE_SIZE, {})
				else
					dc:line(cx + 2, cy + 2, cx + 11, cy + 11, color, 1)
					dc:line(cx + 11, cy + 2, cx + 2, cy + 11, color, 1)
				end
			end
			offset = offset + (horizontal(el) and w or h)
		end
	end
	-- The selected tab's line: slides and stretches from the old tab to the new one
	-- (role tab_indicator); a tab that only moved (a resize) takes it along at once.
	if indicator then
		local x, y, w, h, sel = indicator[1], indicator[2], indicator[3], indicator[4], indicator[5]
		local line = attr(el, "TABSACTIVELINE")
		if t == "TOP" then
			local lx, lw = motion.pair(st, "indicator", x + 8, math.max(0, w - 16), "tab_indicator", { ident = sel })
			dc:fill(lx, y + h - 2, lw, 2, line)
		elseif t == "LEFT" then
			local ly, lh = motion.pair(st, "indicator", y + 8, math.max(0, h - 16), "tab_indicator", { ident = sel })
			dc:fill(x + 7, ly, 2, lh, line)
		end
	end
	local extra_count = integer(attr(el, "EXTRABUTTONS"), 0)
	local extra_used = 0
	for id = 1, extra_count do
		local x, y, w, h = extraRect(el, st, id, extra_used)
		local title = attr(el, "EXTRATITLE" .. id) or ""
		local image = Draw.resolveImage(attr(el, "EXTRAIMAGE" .. id))
		local font = Fonts.get(attr(el, "EXTRAFONT" .. id) or attr(el, "TABSFONT") or attr(el, "FONT"))
		local color = attr(el, "EXTRAFORECOLOR" .. id) or attr(el, "TABSFORECOLOR") or attr(el, "FGCOLOR")
		local active = attr(el, "EXTRAACTIVE" .. id) ~= "NO"
		local selected = yes(attr(el, "EXTRAVALUE" .. id))
		local fill = selected and (attr(el, "TABSSELCOLOR") or attr(el, "BGCOLOR"))
			or (st.data.extraHover == id and (attr(el, "EXTRAHIGHCOLOR" .. id) or attr(el, "HLCOLOR")))
		fill = motion.color(st, "extra" .. id, fill or nil, "hover")
		if active and fill then dc:fill(x, y, w, h, fill, { radius = integer(attr(el, "CORNERRADIUS"), 0) }) end
		local iw, ih = Draw.imageSize(image)
		if image then dc:image(image, x + (w - iw) / 2, y + (h - ih) / 2, iw, ih, {}) end
		if title ~= "" then dc:text(title, x + 6, y + 4, w - 12, h - 8, color, font, { align = "center", valign = "center", ellipsis = true }) end
		extra_used = extra_used + (horizontal(el) and w or h)
	end
	if yes(attr(el, "SHOWLINES")) then
		if horizontal(el) then dc:line(st.x, t == "TOP" and st.y + bh or st.y + st.h - bh, st.x + st.w, t == "TOP" and st.y + bh or st.y + st.h - bh, attr(el, "TABSLINECOLOR"), 1)
		else dc:line(t == "LEFT" and st.x + bw or st.x + st.w - bw, st.y, t == "LEFT" and st.x + bw or st.x + st.w - bw, st.y + st.h, attr(el, "TABSLINECOLOR"), 1) end
	end
end

local function natural(el, st, L)
	local cw, ch = 0, 0
	for _, child in ipairs(pages(el)) do
		local w, h = L.natural(child)
		cw, ch = math.max(cw, w), math.max(ch, h)
	end
	local bw, bh = metrics(el)
	if horizontal(el) then return cw, ch + bh end
	return cw + bw, ch
end
--- iFlatTabsSetChildrenCurrentSizeMethod: every page that is not FLOATING gets the client
-- area as its current size, directly: no EXPAND rule and no MINSIZE/MAXSIZE crop (a page
-- capped by MAXSIZE still fills the strip). IupTabs (`native`) goes through
-- iupBaseSetCurrentSize instead (iTabsSetChildrenCurrentSizeMethod).
local function place_pages(native)
	return function(el, st, L)
		local next_child = ensureCurrent(el)
		if next_child ~= current(el) then setCurrent(el, next_child, false) end
		local x, y, w, h = clientRect(el, st)
		for _, child in ipairs(pages(el)) do
			local cs = Element.state(child)
			local floating, ignore = Layout.floating(cs)
			if not floating then
				if native then L.place(child, x, y, w, h) else L.set(child, x, y, w, h) end
			elseif not ignore then
				Layout.placeFloating(child, cs, st)
			end
		end
	end
end
local place = place_pages(false)

-- The pages: the current one, or both during a page transition.
local function paintChildren(el, st, d, kids, R)
	local tr = st.data.page_tr
	if tr and (tr.to ~= current(el) or not Element.state(tr.from) or not Element.state(tr.to)) then
		st.data.page_tr, tr = nil, nil
	end
	local p = tr and (motion.now() - tr.t0) / tr.dur
	if not tr or p >= 1 then
		st.data.page_tr = nil
		for i = 1, #kids do R.paint(kids[i], d) end
		return
	end
	local x, y, w, h = clientRect(el, st)
	local ctx = PageTransitions.context(tr.spec, w, h, tr.forward)
	local ok, out, inn = pcall(tr.def.frame, tr.ease(p < 0 and 0 or p), ctx)
	if not ok or type(out) ~= "table" or type(inn) ~= "table" then
		st.data.page_tr = nil
		for i = 1, #kids do R.paint(kids[i], d) end
		return
	end
	d:clip_push(x, y, w, h)
	local base = attr(el, "BGCOLOR") or Element.globals.DLGBGCOLOR or "0 0 0"
	if tr.def.backdrop ~= false then d:fill(x, y, w, h, base) end
	local function page(child, t, leaving)
		local alpha = tonumber(t.alpha) or 1
		if alpha <= 0 then return end
		local dx, dy = round(tonumber(t.dx) or 0), round(tonumber(t.dy) or 0)
		d:offset_push(dx, dy)
		d:alpha_push(alpha > 1 and 1 or alpha)
		-- A page draws over the strip's background, so it has none of its own: give it
		-- one here, moving and fading with it, so the arriving page covers the leaving one
		-- as a solid sheet (the IUP build's snapshots are opaque the same way).
		d:fill(x, y, w, h, Element.getAttribute(child, "BGCOLOR") or base)
		if leaving then R.paintHidden(child, d) else R.paint(child, d) end
		d:alpha_pop()
		d:offset_pop()
		local dim = tonumber(t.dim) or 0
		if dim > 0 then d:fill(x + dx, y + dy, w, h, Color.pack(0, 0, 0, 255 * math.min(1, dim))) end
	end
	page(tr.from, out, true)
	page(tr.to, inn, false)
	d:clip_pop()
	motion.keepGoing()
end
local function visibleChildren(el)
	local c = current(el)
	return c and { c } or {}
end

local function setValue(el, st, value, handle)
	local child = handle
	if not child and value then
		for _, c in ipairs(st.children) do
			if own(c, "NAME") == value or attr(c, "NAME") == value or Element.named[value] == c then child = c; break end
		end
	end
	if child and Element.childPos(el, child) >= 0 and visibleAt(el, Element.childPos(el, child)) then
		setCurrent(el, child, true)
	end
	if child then
		st.handles.VALUE_HANDLE = child
		st.handles.VALUE = child
	end
	return false
end
local function setValuePos(el, st, value)
	local pos = tonumber(value)
	local child = pos and st.children[pos + 1]
	if child and visibleAt(el, pos) then setCurrent(el, child, true) end
	return false
end
local function classGetValue(el)
	local child = current(el)
	-- iFlatTabsGetValueAttrib: IupGetName of the child, an automatic one when it has none
	return child and Element.autoName(child) or nil
end
local function classGetValuePos(el)
	local p = currentPos(el)
	return p >= 0 and tostring(p) or nil
end
local function classGetValueHandle(el) return current(el) end
local function classGetCount(el) return #pages(el) end

local function childAdded(el, st, child, pos)
	local p = (pos or #st.children) - 1
	local names = { "TABTITLE", "TABIMAGE", "TABVISIBLE", "TABACTIVE", "TABFORECOLOR", "TABBACKCOLOR", "TABHIGHCOLOR", "TABFONT", "TABTIP" }
	-- iFlatTabsChildAddedMethod: inserted before the last tab, the Id attributes of the
	-- tabs after it move up one, so each keeps its own title, image and state
	for q = #st.children - 1, p + 1, -1 do
		for _, name in ipairs(names) do
			Element.setAttribute(el, name .. q, own(el, name .. (q - 1)))
			Element.setAttribute(el, name .. (q - 1), nil)
		end
	end
	for _, name in ipairs(names) do
		if own(el, name .. p) == nil and own(child, name) ~= nil then Element.setAttribute(el, name .. p, own(child, name)) end
	end
	if own(el, "TABVISIBLE" .. p) == nil then Element.setAttribute(el, "TABVISIBLE" .. p, "YES") end
	if own(el, "TABACTIVE" .. p) == nil then Element.setAttribute(el, "TABACTIVE" .. p, "YES") end
	if not current(el) and visibleAt(el, p) then setCurrent(el, child, false)
	else Element.setAttribute(child, "VISIBLE", "NO") end
end
local function childRemoved(el, st, child, pos)
	local removed_current = st.data.current == child
	for i = pos, #st.children do
		local from = i
		local to = i - 1
		local names = { "TABTITLE", "TABIMAGE", "TABVISIBLE", "TABACTIVE", "TABFORECOLOR", "TABBACKCOLOR", "TABHIGHCOLOR", "TABFONT", "TABTIP" }
		for _, name in ipairs(names) do
			local v = own(el, name .. from)
			Element.setAttribute(el, name .. to, v)
		end
	end
	for _, name in ipairs({ "TABTITLE", "TABIMAGE", "TABVISIBLE", "TABACTIVE", "TABFORECOLOR", "TABBACKCOLOR", "TABHIGHCOLOR", "TABFONT", "TABTIP" }) do
		Element.setAttribute(el, name .. (#st.children), nil)
	end
	if removed_current then setCurrent(el, ensureCurrent(el), false) end
end

local function event(el, st, ev, rt)
	-- IUP's mouse callbacks take the button as '1' '2' '3' and x, y inside the control
	if ev.type == "move" then
		local hit = hitTab(el, st, ev.x, ev.y)
		local extra = hitExtra(el, st, ev.x, ev.y)
		local p = hit and hit or nil
		if st.data.hover ~= p or st.data.extraHover ~= extra then st.data.hover, st.data.extraHover = p, extra; rt.redraw(el) end
		local ret = Element.call(el, "FLAT_MOTION_CB", ev.lx or ev.x - st.x, ev.ly or ev.y - st.y, ev.status or iup._status())
		return ret == iup.IGNORE
	elseif ev.type == "leave" then
		st.data.hover = nil
		Element.call(el, "FLAT_LEAVEWINDOW_CB")
		rt.redraw(el)
		return false
	elseif ev.type == "press" then
		local hit, close = hitTab(el, st, ev.x, ev.y)
		local extra = hitExtra(el, st, ev.x, ev.y)
		local ret = Element.call(el, "FLAT_BUTTON_CB", ev.iupbutton or 48 + ev.button, 1, ev.lx or ev.x - st.x, ev.ly or ev.y - st.y, ev.status or iup._status({ b1 = ev.button == 1 }))
		if ret == iup.IGNORE then return true end
		if ev.button == 3 then
			if hit and activeAt(el, hit) then fireResult(ev, Element.call(el, "RIGHTCLICK_CB", hit)) end
		elseif ev.button == 1 then
			st.data.press = hit
			st.data.closePress = close
			st.data.extraPress = extra
			if extra and attr(el, "EXTRAACTIVE" .. extra) ~= "NO" then
				Element.call(el, "EXTRABUTTON_CB", extra, 1)
			end
		end
		return true
	elseif ev.type == "release" then
		local hit, close = hitTab(el, st, ev.x, ev.y)
		local extra = hitExtra(el, st, ev.x, ev.y)
		local ret = Element.call(el, "FLAT_BUTTON_CB", ev.iupbutton or 48 + ev.button, 0, ev.lx or ev.x - st.x, ev.ly or ev.y - st.y, ev.status or iup._status())
		if ret == iup.IGNORE then st.data.press = nil; return true end
		if ev.button == 1 and st.data.press ~= nil and st.data.press == hit then
			local p = hit
			if st.data.closePress and close and yes(attr(el, "SHOWCLOSE")) then
				local r = Element.call(el, "TABCLOSE_CB", p)
				if r == iup.CONTINUE then Element.destroy(pages(el)[p + 1])
				elseif r == iup.DEFAULT or r == nil then Element.setAttribute(el, "TABVISIBLE" .. p, "NO"); setCurrent(el, ensureCurrent(el), false) end
			elseif p >= 0 and activeAt(el, p) then
				fireResult(ev, setCurrent(el, pages(el)[p + 1], true))
			end
		end
		if ev.button == 1 and extra and st.data.extraPress == extra then
			if yes(attr(el, "EXTRATOGGLE" .. extra)) then
				Element.setAttribute(el, "EXTRAVALUE" .. extra, yes(attr(el, "EXTRAVALUE" .. extra)) and "OFF" or "ON")
			end
			Element.call(el, "EXTRABUTTON_CB", extra, 0)
		end
		st.data.press, st.data.closePress, st.data.extraPress = nil, nil, nil
		rt.redraw(el)
		return true
	elseif ev.type == "key" then
		local key = ev.key
		local p = currentPos(el)
		local nextp
		if key == iup.K_LEFT or key == iup.K_UP then
			for i = p - 1, 0, -1 do if visibleAt(el, i) and activeAt(el, i) then nextp = i; break end end
		elseif key == iup.K_RIGHT or key == iup.K_DOWN or (key == iup.K_TAB and iup.isCtrlXkey(key)) then
			for i = p + 1, #pages(el) - 1 do if visibleAt(el, i) and activeAt(el, i) then nextp = i; break end end
		end
		if nextp then fireResult(ev, setCurrent(el, pages(el)[nextp + 1], true)); rt.redraw(el); return true end
	end
	return false
end

local def = {
	name = "flattabs", children = -1, clip = true, focusable = true, xyToPos = xyToPos,
	paintChildren = paintChildren,
	clipsContent = true, -- iupLayoutMinContent: a page compresses away entirely
	defaults = {
		SHOWTABS = "YES", TABTYPE = "TOP", SHOWLINES = "YES", TABSLINECOLOR = "160 160 160",
		TABSIMAGEPOSITION = "LEFT", TABSIMAGESPACING = "2", TABSALIGNMENT = "ACENTER:ACENTER",
		TABSPADDING = "6x4", TABSTEXTALIGNMENT = "ALEFT", SHOWCLOSE = "NO", TABSBREADTH = "0",
		FOCUSFEEDBACK = "YES", CHILDSIZEALL = "YES", TABACTIVE = "YES", TABVISIBLE = "YES",
		TABSFORECOLOR = function() return Element.globals.DLGFGCOLOR end,
		TABSBACKCOLOR = function() return Element.globals.DLGBGCOLOR end,
	},
	noinherit = { VALUE = true, VALUEPOS = true, VALUE_HANDLE = true, COUNT = true, TABTYPE = true,
		SHOWTABS = true, TABSPADDING = true, TABSBREADTH = true },
	callbacks = {
		TABCHANGE_CB = true, TABCHANGEPOS_CB = true, TABCLOSE_CB = true, RIGHTCLICK_CB = true,
		FLAT_BUTTON_CB = true, FLAT_MOTION_CB = true, FLAT_LEAVEWINDOW_CB = true,
		FLAT_GETFOCUS_CB = true, FLAT_KILLFOCUS_CB = true, EXTRABUTTON_CB = true,
	},
	-- PAGETRANSITIONDRAW: "LIVE", the strip plays page transitions with the live pages
	-- (core.ui.TabTransition stands down for it)
	get = { PAGETRANSITIONDRAW = function() return "LIVE" end,
		VALUE = classGetValue, VALUEPOS = classGetValuePos, VALUE_HANDLE = classGetValueHandle, COUNT = classGetCount,
		-- iFlatTabsGetClientSizeAttrib: the page area, without the tab band (TabOrder takes
		-- the band's height as RASTERSIZE minus this)
		CLIENTSIZE = function(el, st)
			require("core.imgui.Runtime").layoutNow(el)
			local _, _, w, h = clientRect(el, st)
			return string.format("%dx%d", math.max(0, w), math.max(0, h))
		end },
	set = { VALUE = setValue, VALUEPOS = setValuePos, VALUE_HANDLE = setValue },
	childAdded = childAdded, childRemoved = childRemoved,
	natural = natural, place = place, draw = draw, event = event, visibleChildren = visibleChildren,
}

M.flattabs = Classes.define(def)
M.tabs = Classes.define(setmetatable({ name = "tabs", place = place_pages(true) }, { __index = def }))

return M
