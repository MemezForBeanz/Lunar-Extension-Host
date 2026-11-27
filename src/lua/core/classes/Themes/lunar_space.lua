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
-- inside the disc and there is never a full disc and a crescent at once. Its glow stays
-- inside the box (R + 28 of 128), so the layer's box is all it can show.
local MOON_R = 84
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
		('<circle cx="%d" cy="%d" r="%d" fill="url(#h)"/>'):format(cx, cy, R + 28),
		('<circle cx="%d" cy="%d" r="%d" fill="#3A4458" fill-opacity="0.30"/>'):format(cx, cy, R),
		('<path d="M %d %d A %d %d 0 0 1 %d %d %s Z" fill="url(#m)"/>'):format(cx, cy - R, R, R, cx, cy + R, term) }
	-- craters on the lit face only
	for _, cr in ipairs({ { 102, 100, 15, 0.40 }, { 154, 142, 19, 0.34 }, { 118, 166, 9, 0.36 }, { 164, 94, 7, 0.32 },
		{ 176, 164, 8, 0.30 } }) do
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

-- The crescent's outline (the logo's): the limb a near half circle (r 98), the inner edge a
-- flatter arc (r 128), so the body is ~45 units thick at its middle. An arc's radii grow to
-- fit its chord, so the inner arc must be the larger one: two near-equal radii leave a
-- hairline. And its four-point star, in the hollow.
local CRESCENT = 'M 112 22 A 98 98 0 1 0 112 218 A 128 128 0 0 1 112 22 Z'
-- A fill lit along the crescent's limb: a radial gradient round the limb's centre (in the
-- path's own units, turned with it), `stops` = { { offset, colour }, ... } outward.
local function limb(id, stops)
	local out = { ('<radialGradient id="%s" gradientUnits="userSpaceOnUse" cx="112" cy="120" r="98">'):format(id) }
	for _, st in ipairs(stops) do out[#out + 1] = ('<stop offset="%.2f" stop-color="%s"/>'):format(st[1], st[2]) end
	out[#out + 1] = '</radialGradient>'
	return table.concat(out)
end
local STAR = 'M 150 70 L 154 84 L 168 88 L 154 92 L 150 106 L 146 92 L 132 88 L 146 84 Z'

-- The glows' gradients (colour, alpha, mid), for the contrast audit's geometry. A nebula's
-- is the bound its art stays under (a spec checks it point by point).
M.GLOW = { nebula_violet = { "#7457E0", 0.78, 0.60 }, nebula_teal = { "#2F8FA8", 0.72, 0.60 },
	haze = { "#FFFFFF", 0.85, 0.50 } }
local G = M.GLOW

-- A nebula: no disc, but gas. Seven cloudlets drift along one flow, each a few dozen soft
-- ellipses (power-law sizes, stretched along the cloudlet's own heading), over a faint
-- broad bed, with long streaks trailing out, a few brighter knots and dark dust lanes
-- across them; all fading towards the box's ellipse and dimmed in the core, where the
-- clouds pile up. `cols`, darkest to lightest; NanoSVG has no filters, so the softness is
-- each ellipse's own gradient (NEBULA_PROFILE, alpha by its radius).
M.NEBULA_PROFILE = { { 0, 1 }, { 0.25, 0.7 }, { 0.5, 0.35 }, { 0.75, 0.1 }, { 1, 0 } }
M.NEBULA = {
	violet = { seed = 3, gain = 3.0, cols = { "#2E1F9E", "#4A2FD0", "#6B34D8", "#8E3CCB", "#B356D6", "#D79AF0" } },
	teal = { seed = 13, gain = 2.2, cols = { "#10306A", "#16498F", "#1C62A8", "#257CBB", "#3E9BCF", "#86C8E8" } },
}
local NEB_W, NEB_H, NEB_CORE, DUST = 512, 400, 0.6, "#05060E"
--- The ellipses of nebula `n` (M.NEBULA): { x, y, rx, ry, degrees, colour, opacity }.
function M.nebulaBlobs(n)
	local rnd, W, H, cols = rng(n.seed), NEB_W, NEB_H, n.cols
	local cx, cy = W / 2, H / 2
	local function gauss() return (rnd() + rnd() + rnd() - 1.5) / 1.5 end
	local blobs, clouds = {}, {}
	local flow = rnd() * 180
	for k = 0, 6 do
		local px = cx + gauss() * W * 0.24
		local py = cy + gauss() * H * 0.24
		clouds[#clouds + 1] = { px, py, flow + (rnd() - 0.5) * 70, k % #cols }
	end
	for _, c in ipairs(clouds) do
		local spread = W * (0.09 + 0.07 * rnd())
		local t = math.rad(c[3])
		for _ = 1, 34 do
			local rx = math.min(W * 0.16, W * 0.018 / math.max(0.08, rnd()) ^ 0.7)
			local ry = rx * (0.22 + 0.35 * rnd())
			local along = gauss() * spread * 1.8
			local across = gauss() * spread * 0.6
			local x = c[1] + along * math.cos(t) - across * math.sin(t)
			local y = c[2] + along * math.sin(t) + across * math.cos(t)
			local col = cols[1 + math.max(0, math.min(#cols - 2, c[4] + math.floor(rnd() * 3) - 1))]
			local o = rx > W * 0.05 and 0.035 + 0.05 * rnd() or 0.02 + 0.035 * rnd()
			blobs[#blobs + 1] = { x, y, rx, ry, c[3] + (rnd() - 0.5) * 25, col, o }
		end
	end
	local bed = {}
	for _ = 1, 8 do
		local rx = W * (0.24 + 0.16 * rnd())
		local x = cx + gauss() * W * 0.15
		local y = cy + gauss() * H * 0.15
		local ry = rx * (0.5 + 0.3 * rnd())
		local deg = flow + (rnd() - 0.5) * 60
		local col = cols[1 + math.floor(rnd() * 3)]
		bed[#bed + 1] = { x, y, rx, ry, deg, col, 0.05 + 0.04 * rnd() }
	end
	for i = #bed, 1, -1 do table.insert(blobs, 1, bed[i]) end
	for _ = 1, 90 do
		local c = clouds[1 + math.floor(rnd() * #clouds)]
		local t = math.rad(c[3])
		local far = (0.12 + 0.22 * rnd()) * W
		if rnd() >= 0.5 then far = -far end
		local x = c[1] + far * math.cos(t) + gauss() * W * 0.04
		local y = c[2] + far * math.sin(t) + gauss() * W * 0.04
		local rx = W * (0.04 + 0.07 * rnd())
		local ry = rx * (0.10 + 0.14 * rnd())
		local deg = c[3] + (rnd() - 0.5) * 20
		blobs[#blobs + 1] = { x, y, rx, ry, deg, cols[1 + math.max(0, c[4] - 1)], 0.04 + 0.06 * rnd() }
	end
	for _ = 1, 14 do
		local c = clouds[1 + math.floor(rnd() * #clouds)]
		local x = c[1] + gauss() * W * 0.08
		local y = c[2] + gauss() * H * 0.08
		local r = W * (0.006 + 0.012 * rnd())
		blobs[#blobs + 1] = { x, y, r * 1.6, r, c[3], cols[#cols - 2], 0.06 + 0.07 * rnd() }
	end
	for _ = 1, 4 do
		local c = clouds[1 + math.floor(rnd() * #clouds)]
		local x = c[1] + gauss() * W * 0.05
		local y = c[2] + gauss() * H * 0.05
		local rx = W * (0.05 + 0.05 * rnd())
		local ry = rx * (0.22 + 0.15 * rnd())
		local deg = c[3] + (rnd() - 0.5) * 40
		blobs[#blobs + 1] = { x, y, rx, ry, deg, DUST, 0.16 + 0.10 * rnd() }
	end
	for _, b in ipairs(blobs) do
		local d = math.sqrt(((b[1] - cx) / cx) ^ 2 + ((b[2] - cy) / cy) ^ 2)
		local env = math.max(0, 1 - d * d) ^ 0.9
		local u = math.min(1, math.max(0, (d - 0.3) / 0.3))
		env = env * (NEB_CORE + (1 - NEB_CORE) * u * u * (3 - 2 * u))
		b[7] = math.min(1, b[7] * env * n.gain)
	end
	return blobs, W, H
end
local function nebula(n)
	local blobs, W, H = M.nebulaBlobs(n)
	local ids, defs, out = {}, { "<defs>" }, {}
	for _, b in ipairs(blobs) do
		local c = b[6]
		if not ids[c] then
			ids[c] = "n" .. (#defs)
			local stops = {}
			for _, st in ipairs(M.NEBULA_PROFILE) do
				stops[#stops + 1] = ('<stop offset="%.2f" stop-color="%s" stop-opacity="%.2f"/>'):format(st[1], c, st[2])
			end
			defs[#defs + 1] = ('<radialGradient id="%s" cx="50%%" cy="50%%" r="50%%">%s</radialGradient>')
				:format(ids[c], table.concat(stops))
		end
		if b[7] >= 0.002 then
			out[#out + 1] = ('<ellipse cx="%.1f" cy="%.1f" rx="%.1f" ry="%.1f" transform="rotate(%.1f %.1f %.1f)" fill="url(#%s)" opacity="%.4f"/>')
				:format(b[1], b[2], b[3], b[4], b[5], b[1], b[2], ids[c], b[7])
		end
	end
	defs[#defs + 1] = "</defs>"
	return svg(W, H, table.concat(defs) .. table.concat(out))
end

M.SVG = {
	nebula_violet = nebula(M.NEBULA.violet),
	nebula_teal = nebula(M.NEBULA.teal),
	-- the day sky's haze: soft white banks
	haze = svg(512, 256, '<defs>' .. glow("g", unpack(G.haze)) .. '</defs>'
		.. '<ellipse cx="256" cy="128" rx="256" ry="128" fill="url(#g)"/>'),
	galaxy = galaxy(),
	-- the sun: a soft disc, a faint corona and a glow, all inside the box; no rays
	sun = svg(256, 256, '<defs>'
		.. '<radialGradient id="w" cx="50%" cy="50%" r="50%"><stop offset="0" stop-color="#FFE7A8" stop-opacity="0.40"/>'
		.. '<stop offset="1" stop-color="#FFE7A8" stop-opacity="0"/></radialGradient>'
		.. '<radialGradient id="k" cx="50%" cy="50%" r="50%"><stop offset="0.55" stop-color="#FFF1C8" stop-opacity="0.36"/>'
		.. '<stop offset="1" stop-color="#FFF1C8" stop-opacity="0"/></radialGradient>'
		.. '<radialGradient id="c" cx="50%" cy="50%" r="50%"><stop offset="0" stop-color="#FFFDF4"/>'
		.. '<stop offset="0.72" stop-color="#FFF3CC"/><stop offset="0.88" stop-color="#FFE6A6" stop-opacity="0.95"/>'
		.. '<stop offset="1" stop-color="#FFE29A" stop-opacity="0"/></radialGradient></defs>'
		.. '<circle cx="128" cy="128" r="126" fill="url(#w)"/><circle cx="128" cy="128" r="104" fill="url(#k)"/>'
		.. '<circle cx="128" cy="128" r="66" fill="url(#c)"/>'),
	-- the sidebar's crescent (the logo's), lit like the moon: bright along its outer limb,
	-- shaded toward its inner edge (a radial gradient round the limb's centre, 112 120 r 98,
	-- so the horns, all limb, stay bright), in a soft halo, beside a small four-point star
	crescent = svg(200, 240, '<defs>'
		.. limb("c", { { 0.42, "#8E9FB8" }, { 0.62, "#B4C2D6" }, { 0.84, "#DCE4EF" }, { 0.95, "#EEF3FA" }, { 1, "#F8FAFD" } })
		.. glow("h", "#C9D6F0", 0.22, 0.50) .. '</defs>'
		.. '<ellipse cx="96" cy="120" rx="96" ry="118" fill="url(#h)"/>'
		.. '<path d="' .. CRESCENT .. '" fill="url(#c)" transform="rotate(12 100 120)"/>'
		.. '<path d="' .. STAR .. '" fill="#FFFFFF" fill-opacity="0.95"/>'),
	-- by day: a pearl-blue body, its inner edge shaded deeper so the whole shape holds
	-- against the pale rail, in a faint white halo
	crescent_day = svg(200, 240, '<defs>'
		.. limb("c", { { 0.42, "#6F86AF" }, { 0.66, "#7F95BC" }, { 0.88, "#A2B4CE" }, { 1, "#B7C6DB" } })
		.. glow("h", "#FFFFFF", 0.30, 0.50) .. '</defs>'
		.. '<ellipse cx="96" cy="120" rx="96" ry="118" fill="url(#h)"/>'
		.. '<path d="' .. CRESCENT .. '" fill="url(#c)" transform="rotate(12 100 120)"/>'
		.. '<path d="' .. STAR .. '" fill="#7F95BC"/>'),
}
M.MOON_PHASES = {}
for i = 0, 23 do M.MOON_PHASES[i + 1] = moon_phase(i / 23) end

local S = M.SVG
-- Where the bodies sit: px from the window's right and top, so they keep their place in
-- the pages (laid out from the top and the right) at any window size. The preferred place
-- is the band y 325..483 that most pages' right side shares (Media's hero card covers
-- 250..483, the iLO editor 325 and down, Build Queue and Settings leave it open). A body is
-- whole or hidden, never an arc in a gap between two panels: `whole = true` tests its box
-- (art and glow, plus parallax) against the layout actually laid over it and fades it out
-- where it would be partly covered (core.ui.Background.cover).
M.BODY = { x = -192, y = 404, size = 152, parallax = 2 }
-- The sun's path: from below the lower-right horizon at night (fractions of the window) to
-- M.BODY by day, where the moon was. The visible sun follows it, and the crescent is lit
-- from wherever it is on it.
M.SUN = { night = { 0.97, 1.12 }, range = { 0.2, 1 } }
M.MOON = { turn = 40 }
--- The sun at `mode` in a W x H window, px.
local function sun_at(mode, W, H)
	W, H = W or 1920, H or 1080
	local t = (mode - M.SUN.range[1]) / (M.SUN.range[2] - M.SUN.range[1])
	t = t < 0 and 0 or (t > 1 and 1 or t)
	t = t * t * (3 - 2 * t)
	local nx, ny = M.SUN.night[1] * W, M.SUN.night[2] * H
	local dx, dy = W + M.BODY.x, M.BODY.y
	return nx + (dx - nx) * t, ny + (dy - ny) * t
end
M.sun_at = sun_at
local CRESCENT_Y = -230
-- The crescent art is lit on its left (its limb faces 180 degrees): turned so the limb
-- faces the sun.
local function toward_sun(rail_w)
	return function(s)
		local W, H = s.width or 1920, s.height or 1080
		local sx, sy = sun_at(s.mode or 0, W, H)
		local cx, cy = rail_w / 2, H + CRESCENT_Y
		return math.deg(math.atan2(sy - cy, sx - cx)) - 180
	end
end
-- In once the rail has finished extending: slides 32 px in and fades up as `rail_settled`
-- eases 0 -> 1; gone the moment the rail starts to collapse. It never lies under the rail's
-- labels: `rail_room` (px free between the rail's last entry and its foot) fades it out
-- before the entries reach it.
local function crescent(art, rail_w, opacity)
	return { svg = art, width = 150, height = 180, unit = "px", x = rail_w / 2, y = CRESCENT_Y, raster = 1.5, above = true,
		dx = { signal = "rail_settled", from = -32, to = 0, ease = "smooth" },
		opacity = { mul = { { signal = "rail_settled", from = 0, to = 1, ease = "smooth" }, opacity,
			{ signal = "rail_room", from = 0, to = 1, range = { 270, 320 } } } },
		rotation = toward_sun(rail_w),
		deps = { "mode", "width", "height", "rail_settled", "rail_room" },
		parallax = 2, labels = false }
end
-- On a narrow window the pages' controls reach the right of the sheet where the bodies are:
-- the moon and the sun fade out below WIDE px (gone at NARROW), never sitting behind a row.
M.BODIES = { narrow = 1150, wide = 1400 }
local function wide_only(opacity)
	return { mul = { opacity, { signal = "width", from = 0, to = 1, range = { M.BODIES.narrow, M.BODIES.wide } } } }
end
local function sun_x(s) return (sun_at(s.mode or 0, s.width, s.height)) end
local function sun_y(s) local _, y = sun_at(s.mode or 0, s.width, s.height); return y end
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
			{ svg = S.nebula_violet, width = 1200, height = 900, raster = 0.5, x = 0.80, y = 0.36, glow = G.nebula_violet,
				opacity = by_mode(0.75, 0, { 0, 0.55 }), parallax = 5,
				scale = { signal = "time", wave = "sine", period = 40, min = 1, max = 1.04 } },
			{ svg = S.nebula_teal, width = 1000, height = 760, raster = 0.5, x = 0.30, y = 0.78, glow = G.nebula_teal,
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
			-- (only its core, a disc 46/160 of its half side, can pass the veil's bound: `hot` is
			-- that over the box's half diagonal)
			{ svg = S.galaxy, size = 420, raster = 1.1, x = 0.74, y = 0.78, parallax = 8, labels = false, hot = 0.21,
				opacity = by_mode(0.90, 0.80), tint = by_mode("#FFFFFF", "#7F95C2"),
				rotation = { signal = "time", wave = "sine", period = 90, min = -3, max = 3 } },
			-- the moon, right of the pages' content below their header band: it waxes from a
			-- crescent to full as the sky brightens, then fades as the sun takes its place
			-- (its lit disc, R of the art's 128 half side, is what can pass the veil's bound)
			{ svg = { signal = "mode", set = M.MOON_PHASES, range = { 0, 0.5 } }, size = M.BODY.size, unit = "px",
				x = M.BODY.x, y = M.BODY.y, rotation = M.MOON.turn, parallax = M.BODY.parallax, labels = false, hot = 0.47,
				whole = true,
				opacity = wide_only(by_mode(1, 0, { 0.52, 0.72 })) },
			-- the sun rises along its path (M.SUN) as the sky brightens
			{ svg = S.sun, size = M.BODY.size, unit = "px", x = sun_x, y = sun_y, parallax = M.BODY.parallax, labels = false,
				whole = true,
				opacity = wide_only(by_mode(0, 1, { 0.40, 1 })), scale = by_mode(0.7, 1, { 0.4, 1 }),
				deps = { "mode", "width", "height" } },
			-- the extended sidebar's crescent, low in the rail and over the frame's tint (it
			-- never lies under the rail's labels: `rail_room`); silver at night, pearl by day
			crescent(S.crescent, rail_w, by_mode(1, 0, { 0, 0.6 })),
			crescent(S.crescent_day, rail_w, by_mode(0, 1, { 0.4, 1 })),
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
