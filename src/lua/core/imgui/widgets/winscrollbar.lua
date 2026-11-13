-- The Windows scroll bar of IUP's native controls (IupScrollBox, IupCanvas with SCROLLBAR,
-- multiline IupText). On the IUP build these are the system's own bars in the control's
-- non-client area; here they are painted and tracked by the control that owns them.
--
-- Geometry follows what Windows reports through GetScrollBarInfo on the IUP build
-- (scripts/ui_scroll.lua): bars SM_CXVSCROLL = 17 px across, arrow buttons 17 px long (half
-- the bar each when it is shorter than two), the thumb MulDiv(track, page, range) long but
-- at least 8 px, at MulDiv(pos, track - thumb, range - page) past the top arrow.
--
-- Input follows iupwin_canvas.c (winCanvasProcessVerScroll/HorScroll) on top of the system
-- bar's tracking: an arrow is SB_LINEUP/SB_LINEDOWN (LINEX/LINEY from the hash table, else a
-- tenth of the page), the track SB_PAGEUP/SB_PAGEDOWN (repeating until the thumb reaches the
-- pointer), the thumb SB_THUMBTRACK while dragged and SB_THUMBPOSITION on release.
--
-- The look is Windows 11's at rest, as captured on the IUP build: a #F0F0F0 bar with a white
-- line on the content side and a 2 px #858585 thumb on its centre line, no arrows drawn.
-- Under the pointer the system bar widens; that state could not be captured (it needs the
-- real pointer on a visible desktop), so the hover look here (a wider thumb and arrow
-- glyphs) is an approximation.
-- @module core.imgui.widgets.winscrollbar
local Element = require("core.imgui.Element")

local M = {}
M.SIZE = 17       -- iupdrvGetScrollbarSize: SM_CXVSCROLL at 96 DPI
M.MIN_THUMB = 8   -- measured: a page of 120 in 30000 gives an 8 px thumb
-- Auto-repeat of a held arrow or track: not measurable through posted messages; these are
-- the values Wine and ReactOS use for the system bar.
M.FIRST_DELAY, M.REPEAT_DELAY = 0.2, 0.05
-- Colours: core.imgui.syscolors (Windows' light bar under the classic theme, the theme's
-- surfaces otherwise). These name the light values, for reference and tests.
local Sys = require("core.imgui.syscolors")
M.TRACK, M.EDGE, M.THUMB, M.THUMB_END = Sys.LIGHT.scroll_track, Sys.LIGHT.scroll_edge, Sys.LIGHT.scroll_thumb, Sys.LIGHT.scroll_thumb_end
M.DISABLED = Sys.LIGHT.scroll_disabled -- the arrows of a disabled bar

-- IUP's scroll operations (iupcbs.h IUP_SBUP...)
M.OPS = {
	[true] = { lineup = 0, linedown = 1, pageup = 2, pagedown = 3, position = 4, track = 5 },
	[false] = { lineup = 6, linedown = 7, pageup = 8, pagedown = 9, position = 10, track = 11 },
}

local function muldiv(a, b, c)
	if c == 0 then return 0 end
	local v = a * b / c
	return v >= 0 and math.floor(v + 0.5) or -math.floor(-v + 0.5)
end

--- Geometry of one bar along its length: arrow, track, thumb (nil when there is none) and
-- thumb_top, all relative to the bar's start.
function M.geometry(bar)
	local len = bar.vertical and bar.h or bar.w
	local arrow = math.min(M.SIZE, math.floor(len / 2))
	local track = len - 2 * arrow
	local g = { len = len, arrow = arrow, track = track }
	local range = bar.max or 0
	local page = bar.page or 0
	if page < range and track > 0 then
		local thumb = math.max(M.MIN_THUMB, muldiv(track, page, range))
		if thumb <= track then
			local pos = bar.pos or 0
			g.thumb = thumb
			g.thumb_top = arrow + muldiv(pos, track - thumb, range - page)
		end
	end
	return g
end

local function data(e) return Element.state(e).data end

--- Install the visible bars of `e` for this layout: each `{ vertical, x, y, w, h, max, page,
-- pos }` in dialog client coordinates, or nil when that bar is hidden.
function M.set(e, vbar, hbar)
	local d = data(e)
	if vbar then vbar.vertical = true end
	if hbar then hbar.vertical = false end
	d.wsb = { v = vbar, h = hbar }
end

--- The bar (and its part) at dialog client point (x, y).
function M.at(e, x, y)
	local wsb = data(e).wsb
	if not wsb then return nil end
	for _, bar in ipairs({ wsb.v or false, wsb.h or false }) do
		if bar and x >= bar.x and y >= bar.y and x < bar.x + bar.w and y < bar.y + bar.h then
			local q = bar.vertical and (y - bar.y) or (x - bar.x)
			local g = M.geometry(bar)
			local part
			if q < g.arrow then part = "lineup"
			elseif q >= g.len - g.arrow then part = "linedown"
			elseif g.thumb and q >= g.thumb_top and q < g.thumb_top + g.thumb then part = "thumb"
			elseif g.thumb and q < g.thumb_top then part = "pageup"
			elseif g.thumb then part = "pagedown" end
			return bar, part, q, g
		end
	end
	-- the corner between two bars belongs to neither
	if wsb.v and wsb.h and x >= wsb.v.x and y >= wsb.h.y and x < wsb.v.x + wsb.v.w and y < wsb.h.y + wsb.h.h then
		return nil, "corner"
	end
	return nil
end

--- The client rect of `st` once its visible bars are taken off.
function M.client(e, st)
	local wsb = data(e).wsb
	local w, h = st.w, st.h
	if wsb and wsb.v then w = w - wsb.v.w end
	if wsb and wsb.h then h = h - wsb.h.h end
	return st.x, st.y, math.max(0, w), math.max(0, h)
end

--- winCanvasProcessVerScroll / HorScroll: the new position for one operation. `owner` is
-- { range = fn(e, vertical) -> max, page, pos; scroll = fn(e, vertical, pos, op) }.
function M.process(e, owner, vertical, part, trackpos)
	local max, page, pos = owner.range(e, vertical)
	-- "wheel can call this function when scroll bar is empty"
	if page >= max then return false end
	local line = tonumber(Element.own(e, vertical and "LINEY" or "LINEX")) or page / 10
	if owner.step and part ~= "track" and part ~= "position" then
		pos = owner.step(e, vertical, part, pos, page)
		if not pos then return false end
	elseif part == "linedown" then pos = pos + line
	elseif part == "lineup" then pos = pos - line
	elseif part == "pagedown" then pos = pos + page
	elseif part == "pageup" then pos = pos - page
	elseif part == "track" or part == "position" then pos = trackpos
	else return false end
	-- iupCanvasCalcScrollRealPos
	pos = math.max(0, math.min(max - page, pos))
	owner.scroll(e, vertical, pos, M.OPS[vertical][part])
	return true
end

local function step(e, owner, rt)
	local d = data(e)
	local t = d.wsb_track
	if not t or t.part == "thumb" then return end
	local wsb = d.wsb or {}
	local bar = t.vertical and wsb.v or wsb.h
	if not bar then return end
	if t.part == "pageup" or t.part == "pagedown" then
		-- the track repeats only while the thumb has not reached the pointer
		local g = M.geometry(bar)
		if not g.thumb then return end
		if t.part == "pageup" and not (t.q < g.thumb_top) then return end
		if t.part == "pagedown" and not (t.q >= g.thumb_top + g.thumb) then return end
	end
	if t.inside == false then return end
	M.process(e, owner, t.vertical, t.part)
end

--- A press of button 1 at dialog client (x, y). Returns true when it was on a bar.
function M.press(e, owner, x, y, rt)
	local bar, part, q, g = M.at(e, x, y)
	if not bar then return part == "corner" end
	local d = data(e)
	if not part then return true end
	d.wsb_track = { vertical = bar.vertical, part = part, q = q, start = q, inside = true,
		thumb_top = g.thumb_top, next_t = rt and rt.now and (rt.now() + M.FIRST_DELAY) or nil }
	if rt and rt.capture then rt.capture(e) end
	if part ~= "thumb" then step(e, owner, rt) end
	if rt and rt.animate then rt.animate() end
	return true
end

--- Pointer motion while tracking; returns true when a track is in progress.
function M.move(e, owner, x, y, rt)
	local d = data(e)
	local t = d.wsb_track
	if not t then
		local bar, part = M.at(e, x, y)
		local hot = bar and { vertical = bar.vertical, part = part } or nil
		local old = d.wsb_hot
		if (hot and hot.vertical) ~= (old and old.vertical) or (hot and hot.part) ~= (old and old.part) or (hot == nil) ~= (old == nil) then
			d.wsb_hot = hot
			if rt and rt.redraw then rt.redraw(e) end
		end
		return false
	end
	local wsb = d.wsb or {}
	local bar = t.vertical and wsb.v or wsb.h
	if not bar then return true end
	local q = t.vertical and (y - bar.y) or (x - bar.x)
	local across = t.vertical and (x - bar.x) or (y - bar.y)
	local thick = t.vertical and bar.w or bar.h
	if t.part == "thumb" then
		local g = M.geometry(bar)
		if not g.thumb then return true end
		-- Far enough off the bar the thumb goes back to where the drag began (the system bar's
		-- rectangle grown by 8 widths across and 2 along, as Wine/ReactOS do).
		local len = g.len
		local off = across < -8 * thick or across >= thick + 8 * thick or q < -2 * thick or q >= len + 2 * thick
		local top = off and t.thumb_top or math.max(g.arrow, math.min(g.arrow + g.track - g.thumb, t.thumb_top + (q - t.start)))
		local max, page = owner.range(e, t.vertical)
		local pos = (g.track - g.thumb) > 0 and (top - g.arrow) * (max - page) / (g.track - g.thumb) or 0
		if t.last ~= pos then
			t.last = pos
			M.process(e, owner, t.vertical, "track", pos)
		end
	else
		t.q = q
		local _, part = M.at(e, x, y)
		t.inside = part == t.part or ((t.part == "pageup" or t.part == "pagedown") and (part == "pageup" or part == "pagedown"))
	end
	return true
end

--- Button 1 released: SB_THUMBPOSITION after a thumb drag, then the track ends.
function M.release(e, owner, x, y, rt)
	local d = data(e)
	local t = d.wsb_track
	if not t then return false end
	d.wsb_track = nil
	if t.part == "thumb" and t.last then
		M.process(e, owner, t.vertical, "position", t.last)
	end
	if rt and rt.release then rt.release() end
	if rt and rt.redraw then rt.redraw(e) end
	return true
end

--- Auto-repeat; call once per frame while the owner is painted.
function M.tick(e, owner, rt)
	local d = data(e)
	local t = d.wsb_track
	if not t or t.part == "thumb" or not (rt and rt.now) then return end
	local now = rt.now()
	if t.next_t and now >= t.next_t then
		t.next_t = now + M.REPEAT_DELAY
		step(e, owner, rt)
	end
	if rt.animate then rt.animate() end
end

function M.leave(e, rt)
	local d = data(e)
	if d.wsb_hot then d.wsb_hot = nil; if rt and rt.redraw then rt.redraw(e) end end
end

local function draw_bar(dc, bar, hot)
	local g = M.geometry(bar)
	local S = Sys.current
	dc:fill(bar.x, bar.y, bar.w, bar.h, S.scroll_track)
	if bar.vertical then dc:fill(bar.x, bar.y, 1, bar.h, S.scroll_edge) else dc:fill(bar.x, bar.y, bar.w, 1, S.scroll_edge) end
	local thick = bar.vertical and bar.w or bar.h
	local mid = math.floor(thick / 2) -- 8 for 17: the thumb's columns 8 and 9
	-- The arrow glyphs, as captured on a disabled bar (a multiline whose text fits): an 8 px
	-- wide, 6 px deep triangle, its point 6 px (vertical) or 5 px (horizontal) in from the
	-- bar's end, centred on the thumb's line.
	local function arrows(color)
		local function tri(p) dc:poly(p, color, { filled = true }) end
		if bar.vertical then
			local cx, y0, y1 = bar.x + mid + 1, bar.y, bar.y + bar.h
			tri({ cx - 4, y0 + 12, cx + 4, y0 + 12, cx + 1, y0 + 6, cx - 1, y0 + 6 })
			tri({ cx - 4, y1 - 11, cx + 4, y1 - 11, cx + 1, y1 - 5, cx - 1, y1 - 5 })
		else
			local cy, x0, x1 = bar.y + mid + 1, bar.x, bar.x + bar.w
			tri({ x0 + 11, cy - 4, x0 + 11, cy + 4, x0 + 5, cy + 1, x0 + 5, cy - 1 })
			tri({ x1 - 11, cy - 4, x1 - 11, cy + 4, x1 - 5, cy + 1, x1 - 5, cy - 1 })
		end
	end
	if (bar.page or 0) >= (bar.max or 0) then
		-- disabled: the arrows in grey, no thumb
		arrows(S.scroll_disabled)
		return
	end
	if hot then
		-- approximation of the widened bar (see the module header): arrows and an 8 px thumb
		arrows(S.scroll_thumb)
		if g.thumb then
			if bar.vertical then dc:fill(bar.x + mid - 3, bar.y + g.thumb_top, 8, g.thumb, S.scroll_thumb, { radius = 4 })
			else dc:fill(bar.x + g.thumb_top, bar.y + mid - 3, g.thumb, 8, S.scroll_thumb, { radius = 4 }) end
		end
		return
	end
	if not g.thumb then return end
	-- Windows hit-tests an 8 px thumb but paints it at least SM_CYVTHUMB (17) long (measured:
	-- the 8 px thumb of a 120 px view on 30000 is drawn 17 px from the same top)
	local len = math.max(g.thumb, M.SIZE)
	local top = math.min(g.thumb_top, g.arrow + g.track - len)
	g = { thumb = len, thumb_top = math.max(g.arrow, top) }
	if bar.vertical then
		local x, y = bar.x + mid, bar.y + g.thumb_top
		dc:fill(x, y, 2, 1, S.scroll_thumb_end)
		if g.thumb > 2 then dc:fill(x, y + 1, 2, g.thumb - 2, S.scroll_thumb) end
		dc:fill(x, y + g.thumb - 1, 2, 1, S.scroll_thumb_end)
	else
		local x, y = bar.x + g.thumb_top, bar.y + mid
		dc:fill(x, y, 1, 2, S.scroll_thumb_end)
		if g.thumb > 2 then dc:fill(x + 1, y, g.thumb - 2, 2, S.scroll_thumb) end
		dc:fill(x + g.thumb - 1, y, 1, 2, S.scroll_thumb_end)
	end
end

--- Paint the visible bars and the corner between them.
function M.draw(e, st, dc)
	local d = data(e)
	local wsb = d.wsb
	if not wsb then return end
	local active = d.wsb_track or d.wsb_hot
	if wsb.v then draw_bar(dc, wsb.v, active and active.vertical == true) end
	if wsb.h then draw_bar(dc, wsb.h, active and active.vertical == false) end
	if wsb.v and wsb.h then dc:fill(wsb.v.x, wsb.h.y, wsb.v.w, wsb.h.h, Sys.current.scroll_track) end
end

--- What GetScrollBarInfo reports on the IUP build, for scripts/ui_scroll.lua: the bar rect
-- in dialog client coordinates, the arrow size and the thumb's ends along the bar.
function M.info(e, vertical)
	local wsb = data(e).wsb
	local bar = wsb and (vertical and wsb.v or wsb.h)
	if not bar then return nil end
	local g = M.geometry(bar)
	local top = g.thumb_top or g.arrow
	return { x = bar.x, y = bar.y, w = bar.w, h = bar.h, line = g.arrow, thumb_top = top, thumb_bottom = top + (g.thumb or 0) }
end

return M
