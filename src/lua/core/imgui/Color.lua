--- IUP colour strings to packed ImGui colours.
--
-- IUP takes `"r g b"`, `"r g b a"`, `"#rrggbb"`, `"#rrggbbaa"` and the names of
-- global colours (`"DLGBGCOLOR"`, `"TXTHLCOLOR"`...). ImGui wants a 32-bit
-- `0xAABBGGRR`. Parsing is cached: the same few dozen theme colours are converted
-- thousands of times a frame.
--
-- @module core.imgui.Color
local bit = require("bit")
local M = {}

local cache = setmetatable({}, { __mode = "k" })
local strcache = {}
local strcount = 0

--- Globals a colour name may refer to (`Element.globals`, set by the runtime).
M.globals = nil

local function clamp(v)
	v = math.floor(v + 0.5)
	if v < 0 then return 0 end
	if v > 255 then return 255 end
	return v
end

--- Pack r, g, b, a (0..255) into 0xAABBGGRR, as a non-negative Lua number.
function M.pack(r, g, b, a)
	a = a or 255
	return clamp(a) * 16777216 + clamp(b) * 65536 + clamp(g) * 256 + clamp(r)
end

--- Unpack 0xAABBGGRR into r, g, b, a.
function M.unpack(c)
	c = c or 0
	local r = c % 256
	local g = math.floor(c / 256) % 256
	local b = math.floor(c / 65536) % 256
	local a = math.floor(c / 16777216) % 256
	return r, g, b, a
end

local function parse_str(s)
	s = s:match("^%s*(.-)%s*$")
	if s == "" then return nil end
	local hex = s:match("^#(%x+)$")
	if hex then
		if #hex == 6 or #hex == 8 then
			local r = tonumber(hex:sub(1, 2), 16)
			local g = tonumber(hex:sub(3, 4), 16)
			local b = tonumber(hex:sub(5, 6), 16)
			local a = #hex == 8 and tonumber(hex:sub(7, 8), 16) or 255
			return M.pack(r, g, b, a)
		elseif #hex == 3 then
			local r = tonumber(hex:sub(1, 1), 16) * 17
			local g = tonumber(hex:sub(2, 2), 16) * 17
			local b = tonumber(hex:sub(3, 3), 16) * 17
			return M.pack(r, g, b, 255)
		end
		return nil
	end
	local r, g, b, a = s:match("^(%d+)%s+(%d+)%s+(%d+)%s*(%d*)$")
	if r then
		return M.pack(tonumber(r), tonumber(g), tonumber(b), a ~= "" and tonumber(a) or 255)
	end
	r, g, b = s:match("^(%d+)%s*,%s*(%d+)%s*,%s*(%d+)$")
	if r then return M.pack(tonumber(r), tonumber(g), tonumber(b), 255) end
	-- A global colour name: DLGBGCOLOR, TXTHLCOLOR...
	local globals = M.globals
	if globals and s:match("^%u[%u%d_]*$") then
		local v = globals[s]
		if v and v ~= s then return parse_str(v) end
	end
	return nil
end

--- Parse an IUP colour (string or packed number). Returns nil for an empty/invalid one.
function M.parse(value)
	if value == nil then return nil end
	if type(value) == "number" then return value end
	local hit = strcache[value]
	if hit ~= nil then return hit or nil end
	local c = parse_str(tostring(value))
	-- Global names can change with a theme, so they are not cached.
	if not tostring(value):match("^%u") then
		if strcount > 4096 then strcache = {}; strcount = 0 end
		strcache[value] = c or false
		strcount = strcount + 1
	end
	return c
end

--- Forget cached parses (a theme switch redefines global colours).
function M.flush() strcache = {}; strcount = 0 end

--- The colour with its alpha multiplied by `a` (0..1).
function M.alpha(c, a)
	if not c then return nil end
	if a >= 1 then return c end
	local r, g, b, ca = M.unpack(c)
	return M.pack(r, g, b, ca * a)
end

--- Mix two colours: t = 0 gives `c1`, t = 1 gives `c2`.
function M.mix(c1, c2, t)
	if not c1 then return c2 end
	if not c2 then return c1 end
	local r1, g1, b1, a1 = M.unpack(c1)
	local r2, g2, b2, a2 = M.unpack(c2)
	return M.pack(r1 + (r2 - r1) * t, g1 + (g2 - g1) * t, b1 + (b2 - b1) * t, a1 + (a2 - a1) * t)
end

--- IUP's `iupFlatDrawGetIconColor`-style darken/lighten: the offset IUP uses when it
-- derives a pressed or highlight colour from a background (iupDrawCalcShadows).
function M.shade(c, amount)
	local r, g, b, a = M.unpack(c)
	return M.pack(r + amount, g + amount, b + amount, a)
end

--- Luminance 0..255 (IUP's `iupDrawIsDark` threshold is 128... it uses r+g+b < 3*128).
function M.isDark(c)
	local r, g, b = M.unpack(c)
	return (r + g + b) / 3 < 128
end

--- Back to IUP's "r g b" string.
function M.tostring(c)
	local r, g, b, a = M.unpack(c)
	if a ~= 255 then return string.format("%d %d %d %d", r, g, b, a) end
	return string.format("%d %d %d", r, g, b)
end

--- IUP's inactive look: blend toward the background (patch 0005 fades a disabled
-- control toward its surface on dark themes rather than graying it out).
function M.inactive(fg, bg)
	if not fg then return nil end
	if not bg then
		local r, g, b, a = M.unpack(fg)
		local gray = (r + g + b) / 3
		return M.pack((r + gray) / 2, (g + gray) / 2, (b + gray) / 2, a)
	end
	return M.mix(fg, bg, 0.5)
end

M._bit = bit

return M
