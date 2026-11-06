--- A surface colour taken from a picture, so a page wears the colours of what is on it.
-- The result is always dark and moderately saturated: white text stays readable on it
-- whatever the art looks like, and loud art can't shout over the rest of the app.
-- @module libs.tint

local M = {}

local LIGHTNESS = 0.15
local MIN_SATURATION = 0.28
local MAX_SATURATION = 0.55
local SAMPLE_STEP = 8     -- pixels between samples; the average barely changes below this
M.FALLBACK = { 34, 30, 52 }

local function to_hsl(r, g, b)
	r, g, b = r / 255, g / 255, b / 255
	local high, low = math.max(r, g, b), math.min(r, g, b)
	local l = (high + low) / 2
	if high == low then return 0, 0, l end
	local d = high - low
	local s = l > 0.5 and d / (2 - high - low) or d / (high + low)
	local h
	if high == r then h = (g - b) / d + (g < b and 6 or 0)
	elseif high == g then h = (b - r) / d + 2
	else h = (r - g) / d + 4 end
	return h / 6, s, l
end

local function channel(p, q, t)
	if t < 0 then t = t + 1 elseif t > 1 then t = t - 1 end
	if t < 1 / 6 then return p + (q - p) * 6 * t end
	if t < 1 / 2 then return q end
	if t < 2 / 3 then return p + (q - p) * (2 / 3 - t) * 6 end
	return p
end

local function to_rgb(h, s, l)
	local q = l < 0.5 and l * (1 + s) or l + s - l * s
	local p = 2 * l - q
	return math.floor(channel(p, q, h + 1 / 3) * 255 + 0.5), math.floor(channel(p, q, h) * 255 + 0.5),
		math.floor(channel(p, q, h - 1 / 3) * 255 + 0.5)
end

--- Turn any colour into a surface.
-- @tparam number r 0 to 255
-- @tparam number g
-- @tparam number b
-- @treturn table `{ r, g, b }`
function M.surface(r, g, b)
	local h, s = to_hsl(r, g, b)
	if s == 0 then return { M.FALLBACK[1], M.FALLBACK[2], M.FALLBACK[3] } end
	s = math.max(MIN_SATURATION, math.min(MAX_SATURATION, s))
	local nr, ng, nb = to_rgb(h, s, LIGHTNESS)
	return { nr, ng, nb }
end

--- The colour of a BGRA picture, ignoring near-black and near-white, which say nothing about it.
-- @param pixels pointer to 32-bit BGRA rows
-- @tparam number stride bytes per row
-- @tparam number w
-- @tparam number h
-- @treturn table `{ r, g, b }` surface
function M.ofPixels(pixels, stride, w, h)
	local p = require("ffi").cast("const uint8_t*", pixels)
	local total_r, total_g, total_b, count = 0, 0, 0, 0
	for y = 0, h - 1, SAMPLE_STEP do
		local row = y * stride
		for x = 0, w - 1, SAMPLE_STEP do
			local at = row + x * 4
			local b, g, r = p[at], p[at + 1], p[at + 2]
			local high, low = math.max(r, g, b), math.min(r, g, b)
			if high > 40 and low < 235 then
				-- Saturated pixels count for more, so a coloured subject beats a grey sky.
				local weight = 1 + (high - low)
				total_r, total_g, total_b = total_r + r * weight, total_g + g * weight, total_b + b * weight
				count = count + weight
			end
		end
	end
	if count == 0 then return { M.FALLBACK[1], M.FALLBACK[2], M.FALLBACK[3] } end
	return M.surface(total_r / count, total_g / count, total_b / count)
end

--- A colour as IUP writes it.
-- @tparam table colour `{ r, g, b }`
-- @treturn string
function M.attr(colour)
	return string.format("%d %d %d", colour[1], colour[2], colour[3])
end

--- A stable colour for something with no art, from its title.
-- @tparam string title
-- @treturn table `{ r, g, b }` surface
function M.ofTitle(title)
	local hash = 0
	for i = 1, #(title or "") do hash = (hash * 31 + title:byte(i)) % 3600 end
	local r, g, b = to_rgb(hash / 3600, 0.45, 0.5)
	return M.surface(r, g, b)
end

return M
