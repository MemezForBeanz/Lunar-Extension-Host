--- A surface colour taken from a picture, so a page wears the colours of what is on it.
-- The result is moderately saturated and sits at one lightness whatever the art looks like, so
-- text stays readable on it and loud art can't shout over the rest of the app. A dark page gets a
-- dark surface and a light page a pale one: a dark band on a paper-white page reads as harsh.
-- @module libs.tint

local M = {}

local LIGHTNESS = 0.15
local MIN_SATURATION = 0.28
local MAX_SATURATION = 0.55
local LIGHT_LIGHTNESS = 0.9
local LIGHT_MIN_SATURATION = 0.3
local LIGHT_MAX_SATURATION = 0.5
local SAMPLE_STEP = 8     -- pixels between samples; the average barely changes below this
local LIFT = 34           -- how far a quieter control steps off the surface
local LIGHT_LIFT = 26
local LIGHT_TRACK = 0.55  -- a pale surface's seek track, as a share of the surface
M.FALLBACK = { 34, 30, 52 }
M.LIGHT_FALLBACK = { 234, 232, 243 }

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
-- @tparam[opt] boolean light for a light page
-- @treturn table `{ r, g, b }`
function M.surface(r, g, b, light)
	local h, s = to_hsl(r, g, b)
	if s == 0 then
		local fallback = light and M.LIGHT_FALLBACK or M.FALLBACK
		return { fallback[1], fallback[2], fallback[3] }
	end
	local low, high = MIN_SATURATION, MAX_SATURATION
	if light then low, high = LIGHT_MIN_SATURATION, LIGHT_MAX_SATURATION end
	local nr, ng, nb = to_rgb(h, math.max(low, math.min(high, s)), light and LIGHT_LIGHTNESS or LIGHTNESS)
	return { nr, ng, nb }
end

--- The colour of a BGRA picture, ignoring near-black and near-white, which say nothing about it.
-- @param pixels pointer to 32-bit BGRA rows
-- @tparam number stride bytes per row
-- @tparam number w
-- @tparam number h
-- @treturn table|nil `{ r, g, b }` before it becomes a surface, or nil if the picture has no colour
function M.average(pixels, stride, w, h)
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
	if count == 0 then return nil end
	return { total_r / count, total_g / count, total_b / count }
end

--- A surface for a BGRA picture.
-- @param pixels pointer to 32-bit BGRA rows
-- @tparam number stride bytes per row
-- @tparam number w
-- @tparam number h
-- @tparam[opt] boolean light for a light page
-- @treturn table `{ r, g, b }` surface
function M.ofPixels(pixels, stride, w, h, light)
	local colour = M.average(pixels, stride, w, h) or { 128, 128, 128 }
	return M.surface(colour[1], colour[2], colour[3], light)
end

--- A colour as IUP writes it.
-- @tparam table colour `{ r, g, b }`
-- @treturn string
function M.attr(colour)
	return string.format("%d %d %d", colour[1], colour[2], colour[3])
end

--- A stable colour for something with no art, from its title.
-- @tparam string title
-- @tparam[opt] boolean light for a light page
-- @treturn table `{ r, g, b }` surface
function M.ofTitle(title, light)
	local hash = 0
	for i = 1, #(title or "") do hash = (hash * 31 + title:byte(i)) % 3600 end
	local r, g, b = to_rgb(hash / 3600, 0.45, 0.5)
	return M.surface(r, g, b, light)
end

--- Is this page colour a light one?
-- @tparam string|nil colour `R G B`, as a theme palette holds it
-- @treturn boolean
function M.isLight(colour)
	local r, g, b = tostring(colour or ""):match("^%s*(%d+)%s+(%d+)%s+(%d+)")
	if not r then return false end
	return 0.2126 * tonumber(r) + 0.7152 * tonumber(g) + 0.0722 * tonumber(b) >= 128
end

local function step(colour, by)
	return { math.max(0, math.min(255, colour[1] + by)), math.max(0, math.min(255, colour[2] + by)),
		math.max(0, math.min(255, colour[3] + by)) }
end

--- What goes on a surface, each as IUP writes a colour.
-- @tparam table colour `{ r, g, b }` from `surface`
-- @tparam[opt] boolean light the surface is a pale one
-- @treturn table `surface`, `text`, `muted`, `lift` (a quieter control, and a hover), `track` (a seek bar)
function M.scheme(colour, light)
	local lift = light and step(colour, -LIGHT_LIFT) or step(colour, LIFT)
	local track = lift
	if light then
		track = { math.floor(colour[1] * LIGHT_TRACK), math.floor(colour[2] * LIGHT_TRACK),
			math.floor(colour[3] * LIGHT_TRACK) }
	end
	return { surface = M.attr(colour), lift = M.attr(lift), track = M.attr(track),
		text = light and "28 26 36" or "255 255 255", muted = light and "66 64 80" or "204 204 216" }
end

return M
