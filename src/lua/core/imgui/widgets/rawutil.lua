--- Shared pieces of the ports of Lunar's own IUP controls (iup_flatgrid.c, iup_flatrows.c,
-- iup_flatseek.c, iup_flatsegmented.c): C integer arithmetic, iupdrvDrawText's flags, and the
-- provider callbacks `iupraw` installs (src/c/libs/iupraw_wrap.c).
--
-- Coordinates follow the C: relative to the control, inclusive rectangles, and `ox, oy` (the
-- control's origin in the dialog) added when drawing.
-- @module core.imgui.widgets.rawutil
local Element = require("core.imgui.Element")
local Color = require("core.imgui.Color")
local Fonts = require("core.imgui.Fonts")
local FlatDraw = require("core.imgui.widgets.flatdraw")

local M = {}

local floor = math.floor

--- C's int division (truncates toward zero).
function M.idiv(a, b)
	if b == 0 then return 0 end
	local q = a / b
	return q >= 0 and floor(q) or -floor(-q)
end
--- C's % on ints (sign follows the dividend).
function M.imod(a, b) return a - M.idiv(a, b) * b end
--- atoi: leading integer, 0 when there is none.
function M.atoi(v)
	if v == nil then return 0 end
	local n = tostring(v):match("^%s*([%+%-]?%d+)")
	return tonumber(n) or 0
end
function M.max(a, b) return a > b and a or b end
function M.min(a, b) return a < b and a or b end

function M.attr(e, n) return Element.getAttribute(e, n) end
--- iupAttribGetInt / IupGetInt: YES is 1, a number is its integer part.
function M.int(e, n) return FlatDraw.int(Element.getAttribute(e, n), 0) end
function M.bool(e, n) return FlatDraw.bool(Element.getAttribute(e, n)) end
--- iupStrEqualNoCase
function M.eqnc(a, b) return a ~= nil and b ~= nil and tostring(a):upper() == tostring(b):upper() end

--- iupDrawColor(r, g, b, a)
function M.rgba(r, g, b, a) return Color.pack(r, g, b, a or 255) end
--- iupDrawStrToColor(str, default)
function M.strcolor(str, default)
	local c = str and Color.parse(str)
	if c then return c end
	return default
end

--- The control's font (FONT), as IupGetAttribute(ih, "FONT") reads it.
function M.font(e) return Fonts.get(Element.getAttribute(e, "FONT")) end
--- iupdrvFontGetCharSize: average width and line height.
function M.charsize(e) return M.font(e):charsize() end
--- iupdrvFontGetStringWidth
function M.stringwidth(font, s)
	local w = font:measure(s or "")
	return w
end

-- iupdrvDrawText flags (iup_drvdraw.h)
M.LEFT, M.CENTER, M.RIGHT = 0x0000, 0x0001, 0x0002
M.WRAP, M.ELLIPSIS, M.CLIP, M.LAYOUTCENTER = 0x0004, 0x0008, 0x0010, 0x0020

local band = bit.band
--- iupdrvDrawText (the Windows GDI driver): DrawText in (x, y, w, h). LAYOUTCENTER centres a
-- single line vertically; WRAP lays out word wrapped lines from the top; CLIP clips to the box.
function M.text(dc, ox, oy, s, x, y, w, h, color, font, flags)
	if not s or s == "" or not color then return end
	local align = band(flags, M.CENTER) ~= 0 and "center" or band(flags, M.RIGHT) ~= 0 and "right" or "left"
	local wrap = band(flags, M.WRAP) ~= 0
	local valign = (band(flags, M.LAYOUTCENTER) ~= 0 and not wrap) and "center" or "top"
	dc:text(s, ox + x, oy + y, w, h, color, font, {
		align = align, valign = valign, wrap = wrap,
		ellipsis = band(flags, M.ELLIPSIS) ~= 0 and not wrap,
		clip = band(flags, M.CLIP) ~= 0,
	})
end

--- iupdrvDrawRectangle(dc, x1, y1, x2, y2, color, IUP_DRAW_FILL, 1)
function M.fill(dc, ox, oy, x1, y1, x2, y2, color)
	if not color then return end
	if x2 < x1 then x1, x2 = x2, x1 end
	if y2 < y1 then y1, y2 = y2, y1 end
	dc:fill(ox + x1, oy + y1, x2 - x1 + 1, y2 - y1 + 1, color)
end

M.ARROW_LEFT, M.ARROW_TOP, M.ARROW_RIGHT, M.ARROW_BOTTOM = 0, 1, 2, 3
local function iround(v) return floor(v + 0.5) end
--- iupFlatDrawArrow (iup_draw.c): a filled and stroked triangle in a size x size box.
function M.arrow(dc, ox, oy, x, y, size, color_str, bgcolor, active, dir)
	local off1, off2, half = iround(size * 0.13), iround(size * 0.87), M.idiv(size, 2)
	local color = Color.parse(color_str) or 0
	if not active then color = FlatDraw.inactive(color, bgcolor) end
	local p
	if dir == M.ARROW_LEFT then p = { x + off2, y, x + off2, y + size, x + off1, y + half }
	elseif dir == M.ARROW_TOP then p = { x, y + off2, x + size, y + off2, x + half, y + off1 }
	elseif dir == M.ARROW_RIGHT then p = { x + off1, y, x + off1, y + size, x + size - off1, y + half }
	else p = { x, y + off1, x + size, y + off1, x + half, y + size - off1 } end
	for i = 1, 6, 2 do p[i], p[i + 1] = p[i] + ox + 0.5, p[i + 1] + oy + 0.5 end
	dc:poly(p, color, { filled = true })
	dc:poly(p, color, { thickness = 1 })
end

--- iupdrvDrawFocusRect (inclusive corners)
function M.focusrect(dc, ox, oy, x1, y1, x2, y2, color)
	FlatDraw.focusRect(dc, ox, oy, x1, y1, x2, y2, color)
end

-- Provider callbacks -------------------------------------------------------------------
--
-- iupraw stores the Lua functions as the C callbacks the controls look up (CELLVALUE_CB,
-- CELLBITS_CB, ROWVALUE_CB...). A provider error is swallowed as lua_pcall does in the C
-- bridge: the control sees "no value".

local unpack = unpack or table.unpack
--- Call callback `name` and return all its results, or nothing when it is missing or fails.
function M.call(e, name, ...)
	local st = Element.state(e)
	local cb = st and st.cbs[name]
	if not cb then return end
	local r = { xpcall(cb, debug.traceback, e, ...) }
	if not r[1] then
		if Element.hooks.error then Element.hooks.error(e, name, r[2]) end
		return
	end
	return unpack(r, 2, table.maxn(r))
end
function M.has(e, name)
	local st = Element.state(e)
	return st and st.cbs[name] ~= nil
end

--- A provider value as provider_value returns it: a string, or nil.
function M.value(e, cbname, pos, field)
	local v = M.call(e, cbname, pos, field)
	if v == nil then return nil end
	if type(v) == "number" then return tostring(v) end
	if type(v) ~= "string" then return nil end
	return v
end

--- provider_bits: pixels (a lightuserdata, cdata or, in tests, a string) and a stride.
function M.bits(e, cbname, pos, w, h)
	local px, stride = M.call(e, cbname, pos, w, h)
	local t = type(px)
	if t ~= "userdata" and t ~= "cdata" and t ~= "string" then return nil end
	return px, tonumber(stride) or 0
end

return M
