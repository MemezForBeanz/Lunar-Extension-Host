local Classes = require("core.imgui.widgets.flatlist")
local Element = require("core.imgui.Element")
local base = Classes.get("flatlist")
local function own(e, n) return Element.own(e, n) end

local Fonts = require("core.imgui.Fonts")
local iup = require("core.imgui.iup")

-- DROPDOWN=YES: a Win32 combo box (CBS_DROPDOWNLIST), as IUP maps it on Windows. Lunar's
-- own pickers use core.ui.FlatDropdown; a native dropdown is the stock control, drawn
-- here the way it shows on the IUP build (measured with scripts/ui_textmargin.lua): a
-- classic sunken edge, the BGCOLOR/FGCOLOR field, a raised arrow button.
local function is_dropdown(e) return tostring(Element.getAttribute(e, "DROPDOWN") or "NO"):upper() == "YES" end
local function items(e)
	local out, i = {}, 1
	while own(e, tostring(i)) ~= nil do out[i] = tostring(own(e, tostring(i))); i = i + 1 end
	return out
end
local function current(st)
	for i, v in pairs(st.data.selected or {}) do if v then return i end end
	return 0
end
local SB = 17 -- iupdrvGetScrollbarSize (SM_CXVSCROLL at 96 dpi)
-- iListComputeNaturalSizeMethod + iListGetNaturalItemsSize + iupdrvListAddBorders (Windows):
-- one line of text, 2*4 border, 3 for the button's spacing and the button itself; the
-- system sizes a drop-down's height, so RASTERSIZE's height is ignored.
local function dropdown_natural(e, st, L)
	local font = L and L.font(e) or Fonts.forElement(e)
	local _, ch = font:charsize()
	local w
	local cols = tonumber(Element.getAttribute(e, "VISIBLECOLUMNS"))
	if cols and cols > 0 then
		w = math.floor(cols * font:measure("WWWWWWWWWW") / 10)
	else
		w = 0
		for _, v in ipairs(items(e)) do w = math.max(w, font:measure(v)) end
		if w == 0 then w = font:measure("WWWWW") end
	end
	return w + 8 + 3 + SB, math.max(SB, ch + 8)
end
local C = { shadow = "160 160 160", dkshadow = "105 105 105", light = "227 227 227", highlight = "255 255 255",
	face = "240 240 240", text = "0 0 0", sel = "0 120 215", seltext = "255 255 255", border = "100 100 100" }
-- DrawEdge: the outer then the inner line of a two-colour bevel.
local function bevel(dc, x, y, w, h, tl_out, br_out, tl_in, br_in)
	dc:fill(x, y, w, 1, tl_out); dc:fill(x, y, 1, h, tl_out)
	dc:fill(x, y + h - 1, w, 1, br_out); dc:fill(x + w - 1, y, 1, h, br_out)
	dc:fill(x + 1, y + 1, w - 2, 1, tl_in); dc:fill(x + 1, y + 1, 1, h - 2, tl_in)
	dc:fill(x + 1, y + h - 2, w - 2, 1, br_in); dc:fill(x + w - 2, y + 1, 1, h - 2, br_in)
end
local function dropdown_box(e, st)
	local _, h = dropdown_natural(e, st)
	return st.x, st.y, st.w, math.min(st.h, h)
end
local function dropdown_draw(e, st, dc, rt)
	local x, y, w, h = dropdown_box(e, st)
	local font = Fonts.forElement(e)
	local _, ch = font:charsize()
	local bg = Element.getAttribute(e, "BGCOLOR") or C.highlight
	local fg = Element.getAttribute(e, "FGCOLOR") or C.text
	if not Element.isTrue(Element.getAttribute(e, "ACTIVE") or "YES") then fg = "109 109 109" end
	-- EDGE_SUNKEN
	bevel(dc, x, y, w, h, C.shadow, C.highlight, C.dkshadow, C.light)
	dc:fill(x + 2, y + 2, w - 4, h - 4, bg)
	-- DFCS_SCROLLCOMBOBOX: a raised 17 px button inside the edge
	local bx, by, bw, bh = x + w - 2 - SB, y + 2, SB, h - 4
	bevel(dc, bx, by, bw, bh, C.light, C.dkshadow, C.highlight, C.shadow)
	dc:fill(bx + 2, by + 2, bw - 4, bh - 4, C.face)
	local ax, ay = bx + math.floor(bw / 2), by + math.floor(bh / 2) - 1
	for i = 0, 3 do dc:fill(ax - 3 + i, ay + i, 7 - 2 * i, 1, C.text) end
	-- the selection field
	local n = current(st)
	local focused = rt and rt.focused and rt.focused() == e
	local fx, fw = x + 4, w - 7 - SB
	if focused and not st.data.open then
		dc:fill(x + 3, y + 3, fw, h - 6, C.sel)
		fg = C.seltext
	end
	if n > 0 then
		dc:text(own(e, tostring(n)) or "", fx, y + math.floor((h - ch) / 2), fw, ch, fg, font, { clip = true })
	end
end
local function popup_rows(e)
	return math.max(1, math.min(#items(e), tonumber(Element.getAttribute(e, "VISIBLEITEMS")) or 5))
end
local function choose(e, st, i)
	local old = current(st)
	if i < 1 or i > #items(e) or i == old then return end
	st.data.selected, st.data.focus = { [i] = true }, i
	-- winListCallActionCb: the old item with state 0, then the new one with 1
	if old > 0 then Element.call(e, "ACTION", own(e, tostring(old)) or "", old, 0) end
	Element.call(e, "ACTION", own(e, tostring(i)) or "", i, 1)
	Element.call(e, "VALUECHANGED_CB")
	Element.hooks.invalidate(e, "paint", "VALUE")
end
local function close_popup(e, st)
	if st.data.popup and st.data.popup.close then st.data.popup:close() end
	st.data.popup = nil
	if st.data.open then
		st.data.open = false
		Element.call(e, "DROPDOWN_CB", 0)
	end
end
local dropdown_event
local function open_popup(e, st, rt)
	if not rt or not rt.overlay then return end
	local font = Fonts.forElement(e)
	local _, ch = font:charsize()
	local x, y, w, h = dropdown_box(e, st)
	local rows = popup_rows(e)
	st.data.hot = current(st)
	st.data.open = true
	Element.call(e, "DROPDOWN_CB", 1)
	st.data.popup = rt.overlay({ owner = e, x = x, y = y + h, w = w, h = rows * ch + 2, top = 0,
		draw = function(dc, o)
			local list = items(e)
			local bg = Element.getAttribute(e, "BGCOLOR") or C.highlight
			local fg = Element.getAttribute(e, "FGCOLOR") or C.text
			dc:fill(o.x, o.y, o.w, o.h, bg)
			dc:rect(o.x, o.y, o.w, o.h, C.border, { thickness = 1 })
			local top = o.top or 0
			for r = 1, rows do
				local i = top + r
				if not list[i] then break end
				local ry = o.y + 1 + (r - 1) * ch
				local c = fg
				if i == st.data.hot then dc:fill(o.x + 1, ry, o.w - 2, ch, C.sel); c = C.seltext end
				dc:text(list[i], o.x + 3, ry, o.w - 6, ch, c, font, { clip = true })
			end
		end,
		event = function(pev)
			local o = st.data.popup
			if not o then return false end
			if pev.type == "key" then return dropdown_event(e, st, pev, rt) end
			local inside = pev.lx and pev.lx >= 0 and pev.ly >= 0 and pev.lx < o.w and pev.ly < o.h
			local row = inside and (o.top or 0) + math.floor((pev.ly - 1) / ch) + 1 or nil
			if pev.type == "move" and row then st.data.hot = row
			elseif pev.type == "wheel" then
				o.top = math.max(0, math.min(#items(e) - rows, (o.top or 0) - (tonumber(pev.dy) or 0) * 3))
			elseif pev.type == "release" and row then
				choose(e, st, row); close_popup(e, st)
			elseif pev.type == "press" and not inside then close_popup(e, st) end
			return true
		end,
		closed = function() st.data.popup = nil; if st.data.open then st.data.open = false; Element.call(e, "DROPDOWN_CB", 0) end end })
end
function dropdown_event(e, st, ev, rt)
	if ev.type == "press" and ev.button == 1 then
		if st.data.open then close_popup(e, st) else open_popup(e, st, rt) end
		return true
	elseif ev.type == "key" then
		local k = iup.XkeyBase(ev.key)
		local alt = (ev.mods and ev.mods.alt) or (iup.isAltXkey and iup.isAltXkey(ev.key))
		if (k == iup.K_DOWN and alt) or k == iup.K_F4 then
			if st.data.open then close_popup(e, st) else open_popup(e, st, rt) end
		elseif st.data.open and (k == iup.K_CR or k == iup.K_ESC) then
			if k == iup.K_CR then choose(e, st, st.data.hot or 0) end
			close_popup(e, st)
		elseif k == iup.K_DOWN or k == iup.K_UP then
			local n = (st.data.open and st.data.hot or current(st)) + (k == iup.K_DOWN and 1 or -1)
			n = math.max(1, math.min(#items(e), n))
			if st.data.open then st.data.hot = n else choose(e, st, n) end
		elseif k == iup.K_HOME then choose(e, st, 1)
		elseif k == iup.K_END then choose(e, st, #items(e))
		else return false end
		if rt and rt.redraw then rt.redraw(e) end
		return true
	elseif ev.type == "wheel" then
		-- a closed combo with focus steps its selection with the wheel
		if rt and rt.focused and rt.focused() == e then
			choose(e, st, math.max(1, math.min(#items(e), current(st) - ((tonumber(ev.dy) or 0) > 0 and 1 or -1))))
			return true
		end
		return false
	end
	return false
end

local function list_event(e, st, ev, rt)
	local def = base
	if is_dropdown(e) then return dropdown_event(e, st, ev, rt) end
	local r = def.event(e, st, ev, rt)
	if r and (ev.type == "press" or ev.type == "key") then Element.call(e, "ACTION", own(e, tostring(st.data.focus or 0)) or "", st.data.focus or 0, 1) end
	return r
end
local def = {}
for k, v in pairs(base) do def[k] = v end
def.name, def.event = "list", list_event
-- A VALUE given before the items (a constructor table's order is undefined) waits, as
-- IUP keeps attributes set before map and applies them once winListMapMethod has added
-- the items.
local function apply_pending(e, st)
	if not st.data or st.data.value_pending == nil or #items(e) == 0 then return end
	local v = st.data.value_pending
	st.data.value_pending = nil
	base.set.VALUE(e, st, v)
end
def.set = setmetatable({
	VALUE = function(e, st, v)
		if st.data and #items(e) > 0 then st.data.value_pending = nil; return base.set.VALUE(e, st, v) end
		st.pending_value = v
		if st.data then st.data.value_pending = v end
		return false
	end,
}, { __index = base.set })
def.create = function(e, st)
	if base.create then base.create(e, st) end
	st.data.value_pending = st.pending_value
	st.pending_value = nil
end
def.natural = function(e, st, L)
	apply_pending(e, st)
	if is_dropdown(e) then return dropdown_natural(e, st, L) end
	return base.natural(e, st, L)
end
def.draw = function(e, st, dc, rt)
	if is_dropdown(e) then return dropdown_draw(e, st, dc, rt) end
	return base.draw(e, st, dc, rt)
end
def.drawAfter = function(e, st, dc, rt)
	if is_dropdown(e) then return end
	if base.drawAfter then return base.drawAfter(e, st, dc, rt) end
end
def.visibleChildren = function(e, st)
	if is_dropdown(e) then return {} end
	return base.visibleChildren(e, st)
end
def.place = function(e, st, L)
	if is_dropdown(e) then return end
	if base.place then return base.place(e, st, L) end
end
def.defaults = {}
for k, v in pairs(base.defaults or {}) do def.defaults[k] = v end
def.defaults.VISIBLEITEMS = "5"
def.callbacks = { ACTION = true, VALUECHANGED_CB = true, DROPDOWN_CB = true }
Classes.define(def)
return Classes
