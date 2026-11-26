--- Lunar's reactive background (core.ui.Background): a space scene shared by the dark and light
-- modes, so switching mode animates it (`mode` eases 0 -> 1): the night sky brightens into
-- an airy day, the stars fade, the moon's terminator sweeps off its face and it warms into
-- a rising sun; the ringed planet pales into a daytime moon. The crescent belongs to the
-- extended sidebar: it slides in with the rail (`rail`) and is gone when it collapses.
--
-- Text first: everything is low contrast, the bright bodies sit where the sheet's veil
-- softens them or in the frame's corners, and the stars are small. The audit
-- (scripts/theme_contrast.lua) measures labels over `SAMPLES`, the brightest pixel each
-- region can show at any mode or time.
local M = {}

local function svg(w, h, body)
	return ('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d">%s</svg>')
		:format(w, h, w, h, body)
end

-- A soft glow: a radial gradient from `c` at `a` to nothing.
local function glow(id, c, a, mid)
	return ('<radialGradient id="%s" cx="0.5" cy="0.5" r="0.5"><stop offset="0" stop-color="%s" stop-opacity="%.2f"/>'
		.. '<stop offset="%.2f" stop-color="%s" stop-opacity="%.2f"/><stop offset="1" stop-color="%s" stop-opacity="0"/>'
		.. '</radialGradient>'):format(id, c, a, mid or 0.45, c, a * 0.45, c)
end

M.SVG = {
	nebula_violet = svg(512, 400, '<defs>' .. glow("g", "#7457E0", 0.60, 0.40) .. '</defs>'
		.. '<ellipse cx="256" cy="200" rx="256" ry="200" fill="url(#g)"/>'),
	nebula_teal = svg(512, 400, '<defs>' .. glow("g", "#2F8FA8", 0.50, 0.40) .. '</defs>'
		.. '<ellipse cx="256" cy="200" rx="256" ry="200" fill="url(#g)"/>'),
	-- the day sky's haze: soft white banks
	haze = svg(512, 256, '<defs>' .. glow("g", "#FFFFFF", 0.85, 0.50) .. '</defs>'
		.. '<ellipse cx="256" cy="128" rx="256" ry="128" fill="url(#g)"/>'),
	-- a ringed planet, lit from the upper left; its far ring passes behind it
	planet = svg(256, 256, '<defs>'
		.. '<linearGradient id="b" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#C9B8F0"/>'
		.. '<stop offset="0.55" stop-color="#6E5DAF"/><stop offset="1" stop-color="#1E1838"/></linearGradient>'
		.. '<linearGradient id="r" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#E8E0FF" stop-opacity="0.15"/>'
		.. '<stop offset="0.5" stop-color="#E8E0FF" stop-opacity="0.55"/><stop offset="1" stop-color="#E8E0FF" stop-opacity="0.12"/></linearGradient>'
		.. '</defs>'
		.. '<ellipse cx="128" cy="128" rx="120" ry="30" fill="none" stroke="url(#r)" stroke-width="5" transform="rotate(-18 128 128)"/>'
		.. '<circle cx="128" cy="128" r="62" fill="url(#b)"/>'
		.. '<path d="M 70 118 Q 128 100 186 118" stroke="#FFFFFF" stroke-opacity="0.10" stroke-width="5" fill="none"/>'
		.. '<path d="M 68 140 Q 128 124 188 140" stroke="#FFFFFF" stroke-opacity="0.07" stroke-width="4" fill="none"/>'
		-- the near half of the ring, over the planet
		.. '<path d="M 8 128 A 120 30 0 0 0 248 128" fill="none" stroke="url(#r)" stroke-width="5" transform="rotate(-18 128 128)"/>'),
	-- the planet's orbits: thin ellipses, barely there
	orbits = svg(512, 256, '<g fill="none" stroke="#FFFFFF">'
		.. '<ellipse cx="256" cy="128" rx="250" ry="70" stroke-opacity="0.16" stroke-width="1.2"/>'
		.. '<ellipse cx="256" cy="128" rx="190" ry="52" stroke-opacity="0.11" stroke-width="1"/>'
		.. '<circle cx="452" cy="86" r="3.2" fill="#FFFFFF" fill-opacity="0.55" stroke="none"/></g>'),
	-- the moon: a cratered disc
	moon = svg(256, 256, '<defs>'
		.. '<radialGradient id="m" cx="0.38" cy="0.35" r="0.7"><stop offset="0" stop-color="#F4F6FA"/>'
		.. '<stop offset="0.7" stop-color="#C2C8D3"/><stop offset="1" stop-color="#8E95A3"/></radialGradient>'
		.. '</defs>'
		.. '<circle cx="128" cy="128" r="74" fill="url(#m)"/>'
		.. '<circle cx="104" cy="104" r="13" fill="#9EA5B3" fill-opacity="0.45"/>'
		.. '<circle cx="150" cy="140" r="17" fill="#9EA5B3" fill-opacity="0.38"/>'
		.. '<circle cx="118" cy="160" r="8" fill="#9EA5B3" fill-opacity="0.40"/>'
		.. '<circle cx="160" cy="98" r="6" fill="#9EA5B3" fill-opacity="0.35"/>'),
	-- the night's shadow over the moon's face (tinted the sky's colour): a soft terminator
	shade = svg(128, 128, '<defs><radialGradient id="s" cx="0.5" cy="0.5" r="0.5">'
		.. '<stop offset="0" stop-color="#FFFFFF"/><stop offset="0.86" stop-color="#FFFFFF"/>'
		.. '<stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/></radialGradient></defs>'
		.. '<circle cx="64" cy="64" r="64" fill="url(#s)"/>'),
	-- the moon's halo, apart from it, so the shadow never cuts it
	halo = svg(256, 256, '<defs>' .. glow("h", "#DCE4F5", 0.30, 0.50) .. '</defs>'
		.. '<circle cx="128" cy="128" r="126" fill="url(#h)"/>'),
	-- the sun: a warm core in a wide glow, and its rays (they turn slowly)
	sun = svg(256, 256, '<defs>' .. glow("g", "#FFE7A8", 0.70, 0.30)
		.. '<radialGradient id="c" cx="0.5" cy="0.5" r="0.5"><stop offset="0" stop-color="#FFFDF4"/>'
		.. '<stop offset="0.8" stop-color="#FFF1C4"/><stop offset="1" stop-color="#FFE29A"/></radialGradient></defs>'
		.. '<circle cx="128" cy="128" r="126" fill="url(#g)"/><circle cx="128" cy="128" r="40" fill="url(#c)"/>'),
	rays = svg(256, 256, (function()
		local out = { '<g stroke="#FFE9B0" stroke-linecap="round" stroke-opacity="0.55">' }
		for i = 0, 11 do
			local a = i * math.pi / 6
			local r1, r2 = 56, (i % 2 == 0) and 92 or 76
			out[#out + 1] = ('<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke-width="%d"/>'):format(
				128 + r1 * math.cos(a), 128 + r1 * math.sin(a), 128 + r2 * math.cos(a), 128 + r2 * math.sin(a),
				(i % 2 == 0) and 5 or 3)
		end
		out[#out + 1] = '</g>'
		return table.concat(out)
	end)()),
	-- the sidebar's crescent (the logo's): a disc with a disc cut away, lit along its limb,
	-- in a soft halo; a small four-point star beside it
	crescent = svg(200, 240, '<defs>'
		.. '<linearGradient id="c" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#FFFFFF"/>'
		.. '<stop offset="0.6" stop-color="#D5DCE8"/><stop offset="1" stop-color="#9AA4B5"/></linearGradient>'
		.. glow("h", "#C9D6F0", 0.30, 0.50) .. '</defs>'
		.. '<ellipse cx="96" cy="120" rx="96" ry="118" fill="url(#h)"/>'
		.. '<path d="M 112 22 A 92 92 0 1 0 112 218 A 78 84 0 1 1 112 22 Z" fill="url(#c)" transform="rotate(12 100 120)"/>'
		.. '<path d="M 150 70 L 154 84 L 168 88 L 154 92 L 150 106 L 146 92 L 132 88 L 146 84 Z" fill="#FFFFFF" fill-opacity="0.9"/>'),
	-- by day: pearl, its shadow side a pale blue, lighter than the sky's darkest
	crescent_day = svg(200, 240, '<defs>'
		.. '<linearGradient id="c" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#FFFFFF"/>'
		.. '<stop offset="0.65" stop-color="#F1F5FB"/><stop offset="1" stop-color="#D3DEEE"/></linearGradient>'
		.. glow("h", "#FFFFFF", 0.55, 0.50) .. '</defs>'
		.. '<ellipse cx="96" cy="120" rx="96" ry="118" fill="url(#h)"/>'
		.. '<path d="M 112 22 A 92 92 0 1 0 112 218 A 78 84 0 1 1 112 22 Z" fill="url(#c)" transform="rotate(12 100 120)"/>'
		.. '<path d="M 150 70 L 154 84 L 168 88 L 154 92 L 150 106 L 146 92 L 132 88 L 146 84 Z" fill="#FFFFFF"/>'),
}

local S = M.SVG
-- The crescent never lies under the rail's labels: `rail_room` (px free between the rail's
-- last entry and its foot, pushed by the rail) fades it out before its entries reach it.
local function crescent(art, rail_w, opacity)
	return { svg = art, width = 150, height = 180, unit = "px", x = rail_w / 2, y = -230, raster = 1.5,
		dx = { signal = "rail", from = -rail_w, to = 0, range = { 0.15, 1 }, ease = "smooth" },
		opacity = { mul = { { signal = "rail", from = 0, to = 1, range = { 0.35, 1 }, ease = "smooth" }, opacity,
			{ signal = "rail_room", from = 0, to = 1, range = { 270, 320 } } } },
		parallax = 2 }
end
local function by_mode(dark, light, range, ease)
	return { signal = "mode", from = dark, to = light, range = range, ease = ease or "smooth" }
end
M.by_mode = by_mode

--- The scene. `rail_w`: the extended sidebar's width (px), where the crescent sits.
function M.background(rail_w)
	rail_w = rail_w or 176
	local sky_top, sky_bottom = by_mode("#03050B", "#A6C2E4"), by_mode("#0A1122", "#E9F0F8")
	return {
		id = "lunar-space",
		fps = 24,
		layers = {
			{ kind = "fill", top = sky_top, bottom = sky_bottom },
			-- day haze banks rise in as the sky brightens
			{ svg = S.haze, width = 900, height = 360, raster = 0.4, x = 0.30, y = 0.86,
				opacity = by_mode(0, 0.75, { 0.35, 1 }), dy = by_mode(80, 0), parallax = 6 },
			{ svg = S.haze, width = 700, height = 280, raster = 0.5, x = 0.78, y = 0.30,
				opacity = by_mode(0, 0.55, { 0.45, 1 }), dy = by_mode(60, 0), parallax = 4 },
			-- night nebulae fade with the dark
			{ svg = S.nebula_violet, width = 1200, height = 900, raster = 0.35, x = 0.80, y = 0.18,
				opacity = by_mode(0.75, 0, { 0, 0.55 }), parallax = 5,
				scale = { signal = "time", wave = "sine", period = 40, min = 1, max = 1.04 } },
			{ svg = S.nebula_teal, width = 1000, height = 760, raster = 0.4, x = 0.14, y = 0.88,
				opacity = by_mode(0.55, 0, { 0, 0.55 }), parallax = 3 },
			-- far stars: many, faint, slow twinkle, a little parallax
			{ kind = "stars", count = 230, seed = 11, size = { 0.55, 1.5 },
				colors = { "#FFFFFF", "#DDE6FF", "#FFF1DC" },
				twinkle = { amount = 0.45, share = 0.35, period = { 3, 8 } },
				opacity = by_mode(0.40, 0, { 0, 0.6 }), parallax = 3 },
			-- near stars: few, brighter, more parallax
			{ kind = "stars", count = 46, seed = 29, size = { 1.2, 2.6 },
				colors = { "#FFFFFF", "#CFE0FF", "#FFE6C4" },
				twinkle = { amount = 0.55, share = 0.6, period = { 2.5, 6 } },
				opacity = by_mode(0.40, 0, { 0, 0.5 }), parallax = 9 },
			-- the ringed planet and its orbits, lower right; a pale daytime body in light
			{ svg = S.orbits, width = 760, height = 380, x = 0.86, y = 0.84,
				opacity = by_mode(0.85, 0.25), tint = by_mode("#FFFFFF", "#5C7090"), parallax = 7 },
			{ svg = S.planet, size = 300, x = 0.86, y = 0.84, raster = 1.2,
				opacity = by_mode(0.95, 0.40), tint = by_mode("#FFFFFF", "#E8EEF8"), parallax = 8,
				rotation = { signal = "time", wave = "sine", period = 60, min = -2, max = 2 } },
			-- the moon, upper right: night's shadow slides off its face (a crescent waxing
			-- to full), then it fades as the sun takes its place
			{ svg = S.halo, size = 300, raster = 0.5, x = 0.83, y = 0.17, parallax = 6,
				opacity = by_mode(0.55, 0, { 0, 0.7 }) },
			{ svg = S.moon, size = 260, x = 0.83, y = 0.17, parallax = 6,
				opacity = by_mode(1, 0, { 0.45, 0.85 }) },
			{ svg = S.shade, size = 152, x = 0.83, y = 0.17, parallax = 6,
				dx = by_mode(-46, 160, { 0, 0.6 }), dy = by_mode(-18, -40, { 0, 0.6 }),
				tint = by_mode("#04060D", "#6F8FB8", { 0, 0.6 }), opacity = by_mode(1, 0, { 0.3, 0.6 }) },
			{ svg = S.rays, size = 300, x = 0.83, parallax = 6,
				y = by_mode(0.30, 0.17, { 0.4, 1 }), opacity = by_mode(0, 0.9, { 0.55, 1 }),
				scale = by_mode(0.5, 1, { 0.5, 1 }), rotation = { signal = "time", rate = 2.5, wrap = 360 } },
			{ svg = S.sun, size = 300, x = 0.83, parallax = 6,
				y = by_mode(0.30, 0.17, { 0.4, 1 }), opacity = by_mode(0, 1, { 0.45, 1 }),
				scale = by_mode(0.6, 1, { 0.45, 1 }) },
			-- the extended sidebar's crescent, low in the rail: in with the rail, out before it
			-- has collapsed; silver at night (dim enough for the rail's labels), pearl by day
			crescent(S.crescent, rail_w, by_mode(0.55, 0, { 0, 0.6 })),
			crescent(S.crescent_day, rail_w, by_mode(0, 0.92, { 0.4, 1 })),
		},
	}
end

-- The brightest pixel each region can show at any mode and time (sRGB), before the frame's
-- tint, for scripts/theme_contrast.lua: the frame strip (stars at full twinkle, the planet
-- and the crescent's limb), and under the sheet's veil (its blur averages them out).
-- Dark: a star's core at its brightest (the crescent never lies under labels, see above);
-- light: the top of the day sky, its darkest.
M.SAMPLES = {
	dark = { frame = "105 105 110" },
	light = { frame = "166 194 228" },
}

return M
