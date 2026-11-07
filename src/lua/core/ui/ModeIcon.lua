--- The moon and sun: a mark that turns from one into the other.
--
-- At rest the button shows the real icons, `lunar-mark` and Carbon's `light`. These
-- frames only exist between the two, and start and end on the same shapes: a crescent
-- whose cut slides away to leave a disc, which shrinks into the sun's ring while the
-- rays grow and turn into place. NanoSVG has no animation, so each frame is a small
-- SVG, written once and cached by `core.ui.VectorIcon`.
--
-- @module core.ui.ModeIcon
local M = {}

M.FRAMES = 16

-- The crescent of lunar-mark.svg as two circles, and the ring of light.svg.
M.MOON = { x = 14.86, y = 17.14, r = 13, cut_x = 23.71, cut_y = 8.29, cut_r = 12.5 }
M.SUN = { x = 16, y = 16, r = 6, hole = 4, ray_from = 9, ray_to = 14, ray_width = 2 }

local ARC_STEPS = 32

local function lerp(a, b, t) return a + (b - a) * t end

-- 0 until `from`, 1 after `to`, smooth between.
local function span(t, from, to)
	local x = math.max(0, math.min(1, (t - from) / (to - from)))
	return x * x * (3 - 2 * x)
end

local function arc(out, x, y, r, from, to)
	for i = 0, ARC_STEPS do
		local a = lerp(from, to, i / ARC_STEPS)
		out[#out + 1] = { x + r * math.cos(a), y + r * math.sin(a) }
	end
end

--- A circle with a second circle cut out of it, as a closed point list.
-- @treturn table `{ { x, y }, ... }`
function M.crescent(x, y, r, cut_x, cut_y, cut_r)
	local dx, dy = cut_x - x, cut_y - y
	local d = math.sqrt(dx * dx + dy * dy)
	local out = {}
	if d >= r + cut_r or d <= math.abs(r - cut_r) then
		arc(out, x, y, r, 0, math.pi * 2)
		return out
	end
	local toward = math.atan2(dy, dx)
	-- Half the angle of the arc that the cut removes, at each circle's centre.
	local on_outer = math.acos((d * d + r * r - cut_r * cut_r) / (2 * d * r))
	local on_cut = math.acos((d * d + cut_r * cut_r - r * r) / (2 * d * cut_r))
	arc(out, x, y, r, toward + on_outer, toward + math.pi * 2 - on_outer)
	local back = toward + math.pi
	arc(out, cut_x, cut_y, cut_r, back - on_cut, back + on_cut)
	return out
end

local function circle(x, y, r)
	local out = {}
	arc(out, x, y, r, 0, math.pi * 2)
	return out
end

-- One ray, as a rectangle pointing out from the centre.
local function ray(x, y, angle, from, to, width)
	local cx, cy, nx, ny = math.cos(angle), math.sin(angle), -math.sin(angle), math.cos(angle)
	local half = width / 2
	return {
		{ x + cx * from + nx * half, y + cy * from + ny * half },
		{ x + cx * to + nx * half, y + cy * to + ny * half },
		{ x + cx * to - nx * half, y + cy * to - ny * half },
		{ x + cx * from - nx * half, y + cy * from - ny * half },
	}
end

--- The glyph at `t`: 0 is the moon, 1 the sun.
-- @treturn table list of closed point lists, drawn even-odd
function M.shapes(t)
	local moon, sun = M.MOON, M.SUN
	local open = span(t, 0, 0.55)    -- the cut slides off the disc
	local gather = span(t, 0.2, 0.8) -- the disc moves to the centre and shrinks
	local x, y = lerp(moon.x, sun.x, gather), lerp(moon.y, sun.y, gather)
	local r = lerp(moon.r, sun.r, gather)
	local away = open * (moon.r + moon.cut_r)
	local cut_x, cut_y = moon.cut_x + away * 0.7071, moon.cut_y - away * 0.7071
	local shapes = { M.crescent(x, y, r, cut_x, cut_y, moon.cut_r) }

	local hole = sun.hole * span(t, 0.6, 1)
	if hole > 0.05 then shapes[#shapes + 1] = circle(x, y, hole) end

	local grow = span(t, 0.45, 1)
	if grow > 0.01 then
		local turn = (1 - grow) * math.pi / 2
		local to = lerp(sun.ray_from, sun.ray_to, grow)
		for i = 0, 7 do
			shapes[#shapes + 1] = ray(x, y, i * math.pi / 4 + turn, sun.ray_from, to, sun.ray_width)
		end
	end
	return shapes
end

--- SVG text for frame `t`.
function M.svg(t)
	local d = {}
	for _, shape in ipairs(M.shapes(t)) do
		for i, point in ipairs(shape) do
			d[#d + 1] = string.format("%s%.2f %.2f", i == 1 and "M" or "L", point[1], point[2])
		end
		d[#d + 1] = "Z"
	end
	return '<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 32 32">'
		.. '<path fill-rule="evenodd" d="' .. table.concat(d, " ") .. '"/></svg>'
end

return M
