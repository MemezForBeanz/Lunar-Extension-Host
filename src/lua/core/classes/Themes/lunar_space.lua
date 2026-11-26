--- Lunar's reactive background (core.ui.Background): a space scene shared by the dark and light
-- modes, so switching mode animates it (`mode` eases 0 -> 1): the night sky brightens into
-- an airy day, the stars fade, the moon waxes from a crescent to full and gives way to the
-- sun rising into its place; the spiral galaxy pales to a wisp. The crescent belongs to the
-- extended sidebar: it slides in once the rail has finished extending (`rail_settled`) and
-- is gone as it starts to collapse.
--
-- Text first: the bodies sit below the pages' header band, behind the sheet's veil (whose
-- luminance is bounded for its text); the frame strips round the sheet carry labels, so
-- stars there are capped (`frame`) and the bright bodies never reach them. The audit
-- (scripts/theme_contrast.lua) measures labels over `SAMPLES`, derived from the layer table
-- (core.ui.Background.extremes), so they follow the art.
local Background = require("core.ui.Background")
local M = {}

local function svg(w, h, body)
	return ('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d">%s</svg>')
		:format(w, h, w, h, body)
end

-- A soft glow: a radial gradient from `c` at `a` (through `a * 0.45` at `mid`) to nothing.
-- Gradient geometry is in percent of the shape's box: NanoSVG reads a unitless 0.5 as half
-- a user unit, which collapsed every glow to a point.
local function glow(id, c, a, mid)
	return ('<radialGradient id="%s" cx="50%%" cy="50%%" r="50%%"><stop offset="0" stop-color="%s" stop-opacity="%.3f"/>'
		.. '<stop offset="%.2f" stop-color="%s" stop-opacity="%.3f"/><stop offset="1" stop-color="%s" stop-opacity="0"/>'
		.. '</radialGradient>'):format(id, c, a, mid or 0.45, c, a * 0.45, c)
end

-- A seeded generator (the same art every run).
local function rng(seed)
	return function()
		seed = seed * 16807 % 2147483647
		return seed / 2147483647
	end
end

-- The moon at phase `k` (0: a thin crescent, 1: full), lit on its right; the layer turns it
-- toward the night sun. The unlit face is a faint earthshine disc, so the shadow is always
-- inside the disc and there is never a full disc and a crescent at once.
local MOON_R = 74
local function moon_phase(k)
	local cx, cy, R = 128, 128, MOON_R
	local lit = 0.12 + 0.88 * k                 -- the lit share of the face
	local c = 2 * lit - 1                       -- cos of the phase angle: -1 new .. 1 full
	local rx = math.abs(c) * R
	local term
	if rx < 0.5 then term = ("L %d %d"):format(cx, cy - R)
	else term = ("A %.2f %d 0 0 %d %d %d"):format(rx, R, c > 0 and 1 or 0, cx, cy - R) end
	local out = { '<defs>',
		'<radialGradient id="m" cx="62%" cy="40%" r="70%"><stop offset="0" stop-color="#F6F8FB"/>',
		'<stop offset="0.7" stop-color="#C6CCD6"/><stop offset="1" stop-color="#939AA8"/></radialGradient>',
		glow("h", "#DCE4F2", 0.10 + 0.12 * k, 0.55), '</defs>',
		('<circle cx="%d" cy="%d" r="%d" fill="url(#h)"/>'):format(cx, cy, R + 40),
		('<circle cx="%d" cy="%d" r="%d" fill="#3A4458" fill-opacity="0.30"/>'):format(cx, cy, R),
		('<path d="M %d %d A %d %d 0 0 1 %d %d %s Z" fill="url(#m)"/>'):format(cx, cy - R, R, R, cx, cy + R, term) }
	-- craters on the lit face only
	for _, cr in ipairs({ { 104, 104, 13, 0.40 }, { 150, 140, 17, 0.34 }, { 118, 160, 8, 0.36 }, { 160, 98, 6, 0.32 },
		{ 170, 160, 7, 0.30 } }) do
		local dy = cr[2] - cy
		local hw = math.sqrt(math.max(0, R * R - dy * dy))
		if cr[1] - cr[3] * 0.5 > cx - c * hw then
			out[#out + 1] = ('<circle cx="%d" cy="%d" r="%d" fill="#9AA2B1" fill-opacity="%.2f"/>'):format(cr[1], cr[2], cr[3], cr[4])
		end
	end
	return svg(256, 256, table.concat(out))
end

-- The galaxy: light, not lines. A warm core in a faint disc and ~500 soft dots along two
-- logarithmic arms (larger and fainter outward), a few bright stars, seen at a slant.
local function galaxy()
	local out = { '<defs>' .. glow("core", "#FFF2D8", 0.95, 0.22) .. glow("disc", "#9DB4FF", 0.22, 0.45) .. '</defs>',
		'<g transform="translate(160 160) rotate(-24) scale(1 0.46) translate(-160 -160)">',
		'<circle cx="160" cy="160" r="156" fill="url(#disc)"/>' }
	local rnd = rng(5)
	local colors = { "#E6ECFF", "#C9D6FF", "#B9C8FF", "#FFF4E2" }
	for _ = 1, 500 do
		local ph = rnd() < 0.5 and 0 or math.pi
		local t = rnd() ^ 0.8 * 3.4
		local f = t / 3.4
		local r = 14 * math.exp(0.608 * t) + (rnd() - 0.5) * (6 + 22 * f)
		local a = ph + t * 1.7 + (rnd() - 0.5) * (0.18 + 0.25 * f)
		out[#out + 1] = ('<circle cx="%.1f" cy="%.1f" r="%.1f" fill="%s" fill-opacity="%.3f"/>'):format(
			160 + r * math.cos(a), 160 + r * math.sin(a), 2 + 5 * f + rnd() * 0.8,
			colors[1 + math.floor(rnd() * #colors) % #colors], 0.10 - 0.07 * f)
	end
	for _ = 1, 60 do
		local ph = rnd() < 0.5 and 0 or math.pi
		local t = rnd() * 3.4
		local r = 14 * math.exp(0.608 * t) + (rnd() - 0.5) * 18
		local a = ph + t * 1.7 + (rnd() - 0.5) * 0.3
		out[#out + 1] = ('<circle cx="%.1f" cy="%.1f" r="%.1f" fill="#FFFFFF" fill-opacity="%.2f"/>'):format(
			160 + r * math.cos(a), 160 + r * math.sin(a), 0.6 + rnd() * 0.9, 0.20 + rnd() * 0.4)
	end
	out[#out + 1] = '<circle cx="160" cy="160" r="46" fill="url(#core)"/></g>'
	return svg(320, 320, table.concat(out))
end

-- The crescent's outline (the logo's) and its four-point star.
local CRESCENT = 'M 112 22 A 92 92 0 1 0 112 218 A 78 84 0 1 1 112 22 Z'
local STAR = 'M 150 70 L 154 84 L 168 88 L 154 92 L 150 106 L 146 92 L 132 88 L 146 84 Z'

-- The glows' gradients (colour, alpha, mid), for the contrast audit's geometry.
M.GLOW = { nebula_violet = { "#7457E0", 0.60, 0.40 }, nebula_teal = { "#2F8FA8", 0.50, 0.40 },
	haze = { "#FFFFFF", 0.85, 0.50 } }
local G = M.GLOW
M.SVG = {
	nebula_violet = svg(512, 400, '<defs>' .. glow("g", unpack(G.nebula_violet)) .. '</defs>'
		.. '<ellipse cx="256" cy="200" rx="256" ry="200" fill="url(#g)"/>'),
	nebula_teal = svg(512, 400, '<defs>' .. glow("g", unpack(G.nebula_teal)) .. '</defs>'
		.. '<ellipse cx="256" cy="200" rx="256" ry="200" fill="url(#g)"/>'),
	-- the day sky's haze: soft white banks
	haze = svg(512, 256, '<defs>' .. glow("g", unpack(G.haze)) .. '</defs>'
		.. '<ellipse cx="256" cy="128" rx="256" ry="128" fill="url(#g)"/>'),
	galaxy = galaxy(),
	-- the sun: a soft disc, a faint corona and a wide glow; no rays
	sun = svg(256, 256, '<defs>'
		.. '<radialGradient id="w" cx="50%" cy="50%" r="50%"><stop offset="0" stop-color="#FFE7A8" stop-opacity="0.35"/>'
		.. '<stop offset="1" stop-color="#FFE7A8" stop-opacity="0"/></radialGradient>'
		.. '<radialGradient id="k" cx="50%" cy="50%" r="50%"><stop offset="0.45" stop-color="#FFF1C8" stop-opacity="0.32"/>'
		.. '<stop offset="1" stop-color="#FFF1C8" stop-opacity="0"/></radialGradient>'
		.. '<radialGradient id="c" cx="50%" cy="50%" r="50%"><stop offset="0" stop-color="#FFFDF4"/>'
		.. '<stop offset="0.72" stop-color="#FFF3CC"/><stop offset="0.88" stop-color="#FFE6A6" stop-opacity="0.95"/>'
		.. '<stop offset="1" stop-color="#FFE29A" stop-opacity="0"/></radialGradient></defs>'
		.. '<circle cx="128" cy="128" r="126" fill="url(#w)"/><circle cx="128" cy="128" r="72" fill="url(#k)"/>'
		.. '<circle cx="128" cy="128" r="40" fill="url(#c)"/>'),
	-- the sidebar's crescent (the logo's): lit along its limb, in a soft halo, beside a
	-- small four-point star
	crescent = svg(200, 240, '<defs>'
		.. '<linearGradient id="c" x1="0%" y1="0%" x2="100%" y2="100%"><stop offset="0" stop-color="#FFFFFF"/>'
		.. '<stop offset="0.6" stop-color="#D5DCE8"/><stop offset="1" stop-color="#9AA4B5"/></linearGradient>'
		.. glow("h", "#C9D6F0", 0.30, 0.50) .. '</defs>'
		.. '<ellipse cx="96" cy="120" rx="96" ry="118" fill="url(#h)"/>'
		.. '<path d="' .. CRESCENT .. '" fill="url(#c)" transform="rotate(12 100 120)"/>'
		.. '<path d="' .. STAR .. '" fill="#FFFFFF" fill-opacity="0.9"/>'),
	-- by day: a filled pearl body (no strokes) in a faint white halo
	crescent_day = svg(200, 240, '<defs>'
		.. '<linearGradient id="c" x1="0%" y1="0%" x2="100%" y2="100%"><stop offset="0" stop-color="#DCE6F3"/>'
		.. '<stop offset="1" stop-color="#93A8C6"/></linearGradient>'
		.. glow("h", "#FFFFFF", 0.25, 0.50) .. '</defs>'
		.. '<ellipse cx="96" cy="120" rx="96" ry="118" fill="url(#h)"/>'
		.. '<path d="' .. CRESCENT .. '" fill="url(#c)" fill-opacity="0.85" transform="rotate(12 100 120)"/>'
		.. '<path d="' .. STAR .. '" fill="#93A8C6" fill-opacity="0.85"/>'),
}
M.MOON_PHASES = {}
for i = 0, 23 do M.MOON_PHASES[i + 1] = moon_phase(i / 23) end

local S = M.SVG
-- The sun's path (fractions of the window): below the lower-right horizon at night, risen
-- by day to where the moon was (below the pages' header band, right of their content). The
-- visible sun follows it, and the crescent is lit from wherever it is on it.
M.SUN = { night = { 0.97, 1.12 }, day = { 0.90, 0.46 }, range = { 0.2, 1 } }
M.MOON = { x = 0.90, y = 0.46, size = 180, turn = 40 }
local function sun_at(mode)
	local t = (mode - M.SUN.range[1]) / (M.SUN.range[2] - M.SUN.range[1])
	t = t < 0 and 0 or (t > 1 and 1 or t)
	t = t * t * (3 - 2 * t)
	local n, d = M.SUN.night, M.SUN.day
	return n[1] + (d[1] - n[1]) * t, n[2] + (d[2] - n[2]) * t
end
M.sun_at = sun_at
local CRESCENT_Y = -230
-- The crescent art is lit on its left (its limb faces 180 degrees): turned so the limb
-- faces the sun.
local function toward_sun(rail_w)
	return function(s)
		local W, H = s.width or 1920, s.height or 1080
		local sx, sy = sun_at(s.mode or 0)
		local cx, cy = rail_w / 2, H + CRESCENT_Y
		return math.deg(math.atan2(sy * H - cy, sx * W - cx)) - 180
	end
end
-- In once the rail has finished extending: slides 32 px in and fades up as `rail_settled`
-- eases 0 -> 1; gone the moment the rail starts to collapse. It never lies under the rail's
-- labels: `rail_room` (px free between the rail's last entry and its foot) fades it out
-- before the entries reach it.
local function crescent(art, rail_w, opacity)
	return { svg = art, width = 150, height = 180, unit = "px", x = rail_w / 2, y = CRESCENT_Y, raster = 1.5,
		dx = { signal = "rail_settled", from = -32, to = 0, ease = "smooth" },
		opacity = { mul = { { signal = "rail_settled", from = 0, to = 1, ease = "smooth" }, opacity,
			{ signal = "rail_room", from = 0, to = 1, range = { 270, 320 } } } },
		rotation = toward_sun(rail_w),
		deps = { "mode", "width", "height", "rail_settled", "rail_room" },
		parallax = 2, labels = false }
end
local function sun_x(s) return (sun_at(s.mode or 0)) end
local function sun_y(s) local _, y = sun_at(s.mode or 0); return y end
local function by_mode(dark, light, range, ease)
	return { signal = "mode", from = dark, to = light, range = range, ease = ease or "smooth" }
end
M.by_mode = by_mode

-- Stars in the frame strips (where labels sit) are capped at this; behind the sheet the
-- veil bounds what they do to its text, so there they may be brighter.
M.FRAME_STARS = 0.34
-- Behind the sheet a star's core, over the brightest night sky and a nebula's peak, under
-- the veil's tint must stay inside its luminance bound (0.0622): the veil draws its body as
-- a plain fill there, bounding only where the moon and the galaxy's core are (Glass).
M.BODY_STARS = 0.50
-- The strips round the sheet where the frame's labels lie (px): the title strip, the
-- status strip and the rail (with the sheet's gap), as wide as the rail is.
local function labels(rail_w)
	return { top = 46, bottom = 30, left = { signal = "rail", from = 48 + 12, to = rail_w + 12 } }
end
local function frame_band(rail_w)
	local l = labels(rail_w)
	l.opacity = M.FRAME_STARS
	return l
end

--- The scene. `rail_w`: the extended sidebar's width (px), where the crescent sits.
function M.background(rail_w)
	rail_w = rail_w or 176
	local sky_top, sky_bottom = by_mode("#03050B", "#8FB3E0"), by_mode("#0A1122", "#E9F0F8")
	return {
		id = "lunar-space",
		fps = 24,
		labels = labels(rail_w),
		layers = {
			{ kind = "fill", top = sky_top, bottom = sky_bottom },
			-- day haze banks rise in as the sky brightens
			{ svg = S.haze, width = 900, height = 360, raster = 0.4, x = 0.30, y = 0.86, glow = G.haze,
				opacity = by_mode(0, 0.75, { 0.35, 1 }), dy = by_mode(80, 0), parallax = 6 },
			{ svg = S.haze, width = 700, height = 280, raster = 0.5, x = 0.70, y = 0.62, glow = G.haze,
				opacity = by_mode(0, 0.55, { 0.45, 1 }), dy = by_mode(60, 0), parallax = 4 },
			-- night nebulae fade with the dark
			{ svg = S.nebula_violet, width = 1200, height = 900, raster = 0.35, x = 0.80, y = 0.36, glow = G.nebula_violet,
				opacity = by_mode(0.75, 0, { 0, 0.55 }), parallax = 5,
				scale = { signal = "time", wave = "sine", period = 40, min = 1, max = 1.04 } },
			{ svg = S.nebula_teal, width = 1000, height = 760, raster = 0.4, x = 0.30, y = 0.78, glow = G.nebula_teal,
				opacity = by_mode(0.55, 0, { 0, 0.55 }), parallax = 3 },
			-- far stars: many, faint, slow twinkle, a little parallax
			{ kind = "stars", count = 320, seed = 11, size = { 0.9, 2.0 },
				colors = { "#FFFFFF", "#DDE6FF", "#FFF1DC" },
				twinkle = { amount = 0.45, share = 0.35, period = { 3, 8 } },
				opacity = by_mode(M.BODY_STARS, 0, { 0, 0.6 }), frame = frame_band(rail_w), parallax = 3 },
			-- near stars: few, brighter, more parallax
			{ kind = "stars", count = 46, seed = 29, size = { 1.6, 3.0 },
				colors = { "#FFFFFF", "#CFE0FF", "#FFE6C4" },
				twinkle = { amount = 0.55, share = 0.6, period = { 2.5, 6 } },
				opacity = by_mode(M.BODY_STARS, 0, { 0, 0.5 }), frame = frame_band(rail_w), parallax = 9 },
			-- a spiral galaxy, lower right, swaying a few degrees over a minute and a half; by day
			-- a pale wisp
			-- (only its core, a 46/160 disc, can pass the veil's bound: `hot`)
			{ svg = S.galaxy, size = 420, raster = 1.1, x = 0.74, y = 0.78, parallax = 8, labels = false, hot = 0.32,
				opacity = by_mode(0.90, 0.30), tint = by_mode("#FFFFFF", "#B8C8E8"),
				rotation = { signal = "time", wave = "sine", period = 90, min = -3, max = 3 } },
			-- the moon, right of the pages' content below their header band: it waxes from a
			-- crescent to full as the sky brightens, then fades as the sun takes its place
			{ svg = { signal = "mode", set = M.MOON_PHASES, range = { 0, 0.5 } }, size = M.MOON.size,
				x = M.MOON.x, y = M.MOON.y, rotation = M.MOON.turn, parallax = 6, labels = false, hot = 0.62,
				opacity = by_mode(1, 0, { 0.52, 0.72 }) },
			-- the sun rises along its path (M.SUN) as the sky brightens
			{ svg = S.sun, size = 300, x = sun_x, y = sun_y, parallax = 6, labels = false,
				opacity = by_mode(0, 1, { 0.40, 1 }), scale = by_mode(0.7, 1, { 0.4, 1 }), deps = { "mode" } },
			-- the extended sidebar's crescent, low in the rail; silver at night (dim enough for
			-- the rail's labels), pearl by day
			crescent(S.crescent, rail_w, by_mode(0.55, 0, { 0, 0.6 })),
			crescent(S.crescent_day, rail_w, by_mode(0, 0.92, { 0.4, 1 })),
		},
	}
end

-- The worst pixel each mode's scene can put under the frame's labels (sRGB), before the
-- frame's tint, for scripts/theme_contrast.lua: dark, the brightest (a capped star's core
-- over the nebulae and the sky); light, the darkest (the top of the day sky).
local function sample(c, up)
	local r = up and math.ceil or math.floor
	return ("%d %d %d"):format(r(c[1] - 1e-9), r(c[2] - 1e-9), r(c[3] - 1e-9))
end
do
	local bg = M.background()
	local bright = Background.extremes(bg, { mode = 0 })
	local _, dark = Background.extremes(bg, { mode = 1 })
	M.SAMPLES = { dark = { frame = sample(bright, true) }, light = { frame = sample(dark, false) } }
end

return M
