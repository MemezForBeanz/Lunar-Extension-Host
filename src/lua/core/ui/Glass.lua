--- Lunar's Liquid Glass: a static backdrop and the glass surfaces that sample it.
--
-- The backdrop (an oversized crescent along the upper-left perimeter and, in the dark mode,
-- a baked starfield) is a pre-baked image per mode under assets/glass, made offline by
-- scripts/gen_glass_assets.py. It is loaded and uploaded once per mode and kept: resizing
-- the window or switching light/dark never generates or uploads pixels again
-- (`stats().generations` counts the loads). The GPU stretches it to the window with
-- "cover" scaling anchored at the top-left corner, so the crescent stays put.
--
-- Every surface is a fixed number of draw calls whatever its size or radius:
--   floor     the sharp backdrop, one image
--   chrome    title strip, rail, status bar, inset transport: the softened backdrop in one
--             rounded image, a tint, one rim
--   floating  menus, palette, toasts, tooltips, dialogs: a nine-slice shadow, the softened
--             backdrop, a tint, one rim
--   card      the matte work sheet: an opaque rounded fill and a faint rim
--   veil      the work sheet over a reactive background (core.ui.Background): on the GPU, chrome
--             glass sampling the live scene (blurred body, a refracting rim, the sheet's
--             tint at `glassVeilAlpha`, luminance bounded for its text); otherwise the card
--   content / chrome_content / none   children of the above: nothing (the parent's glass
--             shows; the runtime skips their own fill of the material colour)
--
-- On a hardware device (B.glass_ready(), asked once per frame) chrome and floating glass are
-- a live shader instead (lunar_glass_d3d11.inc): each surface is one `glass` call that
-- refracts and blurs what is actually under it this frame, with one specular lobe on its
-- rim, an inner shade and the same tints; floating glass eases into its opaque text well
-- over 6 px, a tooltip is frosted glass throughout, and the Media transport shows the
-- nearest artwork extended under it. The lobe turns up to 20 degrees toward the pointer
-- near a surface (fixed with reduced motion). The floating shadow stays as below. On WARP,
-- an SDL host, or with hardware acceleration off, the baked path below is used unchanged.
-- The floor (the backdrop the glass refracts) and the matte card are the same on both
-- paths.
--
-- Without the backend's glass calls (an older exe) the sample falls back to clipped strips;
-- with glass off, or no image, surfaces get their solid fills and the same layout.
-- @module core.ui.Glass
local Color = require("core.imgui.Color")
local Reactor = require("core.ui.ThemeReactor")
local M = {}
local enabled, cache, theme, rules, floating_dialog = true
local asset_dir
local floor, ceil, min, max = math.floor, math.ceil, math.min, math.max

-- Floating shadow: offset (0, 6), 18 px falloff, from a 96 px nine-slice whose corners
-- hold 24 px of falloff around a 16 px radius (see gen_glass_assets.py).
local SHADOW_PAD, SHADOW_OFFSET, SHADOW_BORDER, SHADOW_TEX = 24, 6, 40, 96
-- How far the sample is pulled in at the rim: the backdrop bends through the curved edge.
local REFRACT = 2

local shapes = setmetatable({}, { __index = function(t, r) local v = { radius = r }; rawset(t, r, v); return v end })
-- the matte card's corners: finer arcs (they stepped at native size)
local fine_shapes = setmetatable({}, { __index = function(t, r) local v = { radius = r, fine = true }; rawset(t, r, v); return v end })

local function release()
	if cache and cache.B and cache.B.texture_free then
		for _, c in pairs(cache.by_key) do
			if c.sharp then cache.B.texture_free(c.sharp) end
			if c.blur then cache.B.texture_free(c.blur) end
		end
		if cache.shadow then cache.B.texture_free(cache.shadow) end
	end
	cache = nil
end

function M.setEnabled(value) enabled = value == true; if not enabled then release() end end

-- The shader's optics. `band`: px in from the rim over which the lens falls off;
-- `thickness`: how far it pulls the view in at the rim (px); `chroma`: the split per
-- channel at the rim (px); `rim_blur`: the blur's share at the rim, reaching all blur
-- `blur_depth` px in; `well_ease`: px over which a floating lip eases into its opaque well.
-- Floating glass is an 8 px lens pulling 5 px at the rim, so it reads as a curved slab of
-- glass, not a card with a rim. Every floating surface is 90% blur at the rim and all blur
-- by 2 px, over the strong (16 px) blur (`soft`), so no text under its lip shows as glyphs
-- or grey smears; the palette and Activity (`chroma` in their rule) also split a quarter px.
-- The transport's tint leaves the artwork a quarter of the result (light: LIGHT_ART).
M.LENS = {
	floating = { band = 8, thickness = 5, chroma = 0, rim_blur = 0.9, blur_depth = 2, soft = true, well_ease = 6 },
	split = { rim_blur = 0.9, blur_depth = 2, soft = true },
	frost = { band = 4, thickness = 3, chroma = 0, rim_blur = 0.9, blur_depth = 2 },
	chrome = { band = 8, thickness = 4, chroma = 0.6 },
	live = { band = 6, thickness = 3, chroma = 0.25, tint = 0.75, rim_blur = 0.65, blur_depth = 3 },
	-- the sheet over a reactive background: a wide, gentle lens, so the stars bend at its edge
	veil = { band = 14, thickness = 6, chroma = 0.35 },
}
-- The nearest artwork under the transport: whole for ART_HOLD px past the poster, then
-- fading to nothing over the next ART_FADE px (ART_REACH in all). The light mode holds
-- 12 px and fades over 24 (LIGHT_ART) under a lighter tint (60%), the artwork 7/8 opaque
-- under it so it keeps 35% of the result: a violet-to-pearl run along the capsule.
M.ART_HOLD, M.ART_FADE = 12, 12
M.ART_REACH = M.ART_HOLD + M.ART_FADE
M.LIGHT_ART = { hold = 12, fade = 24, tint = 0.60, share = 0.35 }
-- The light turns toward a pointer over or within `range` px of a surface, by up to `turn`.
M.LIGHT = { range = 48, turn = math.rad(20) }
-- A tooltip: frosted glass throughout (no opaque well), lit like the rest.
M.TIP_STATE, M.TIP_STYLE = {}, { frost = true }

--- Which path this frame's glass takes on `dc`: "shader" (a live hardware device) or "baked".
function M.path(dc)
	local v = dc.glass_gpu
	if v == nil then
		local B = dc.B
		v = (B.glass and B.glass_ready and B.glass_ready()) and true or false
		dc.glass_gpu = v
	end
	return v and "shader" or "baked"
end
local function gpu(dc) return M.path(dc) == "shader" end
function M.enabled() return enabled end
function M.clear() release(); theme, rules, floating_dialog = nil, nil, nil end
--- Where the baked images live (assets/glass next to the exe).
function M.setAssetDir(dir) if dir ~= asset_dir then release(); asset_dir = dir end end
function M.assetDir() return asset_dir end
function M.stats()
	local bytes = 0
	if cache then
		for _, c in pairs(cache.by_key) do bytes = bytes + (c.bytes or 0) end
		bytes = bytes + (cache.shadow_bytes or 0)
	end
	return { bytes = bytes, generations = M.generations or 0 }
end

local function load_png(name)
	if not asset_dir then return nil end
	local ok, codec = pcall(require, "imagecodec")
	if not ok or not codec.png_rgba then return nil end
	local sep = asset_dir:find("\\", 1, true) and "\\" or "/"
	local pixels, w, h = codec.png_rgba(asset_dir .. sep .. name)
	if not pixels then return nil end
	return pixels, w, h
end
M._load_png = load_png -- specs replace it

--- Solid-colour stand-in for a palette without a baked image: its floor colour, 2x2.
local function flat_pixels(p)
	local r, g, b = Color.unpack(Color.parse(p.bg))
	local px = string.char(r, g, b, 255)
	return px:rep(4), 2, 2
end

-- Colours resolved once per palette, not per surface per frame.
local function looks(p)
	local dark = p.glassDark
	local function col(v, fallback) return Color.parse(v or fallback) end
	return {
		chrome = Color.alpha(col(p.glassChromeTint, p.layer01), p.glassChromeAlpha or (dark and 0.32 or 0.36)),
		floating = Color.alpha(col(p.glassFloatingTint, p.layer03), p.glassFloatingAlpha or (dark and 0.24 or 0.22)),
		-- the baked lip (WARP, no blur chain): a heavier tint, so text under it stays a smear
		floating_baked = Color.alpha(col(p.glassFloatingTint, p.layer03),
			(p.glassFloatingAlpha or (dark and 0.24 or 0.22)) * M.BAKED_LIP_TINT),
		well = col(p.glassTextWell, p.layer03),
		-- the well's last two pixels blend into the lip instead of ending in an edge
		well_feather = { Color.alpha(col(p.glassTextWell, p.layer03), 0.35), Color.alpha(col(p.glassTextWell, p.layer03), 0.5) },
		rim_hi = col(p.glassRimHi, dark and "255 255 255 115" or "255 255 255 153"),
		rim_lo = col(p.glassRimLo, dark and "255 255 255 20" or "255 255 255 26"),
		rim_inner = col(p.glassRimInner, dark and "0 0 0 36" or "0 0 0 23"),
		shadow = Color.pack(0, 0, 0, floor(255 * (p.glassShadowAlpha or (dark and 0.32 or 0.17)) + 0.5)),
		card_rim = col(p.glassCardRim, dark and "255 255 255 15" or "0 0 0 15"),
		-- the shader's rim: one lobe peaking toward the light over a floor, a faint shade
		spec = Color.pack(255, 255, 255, floor(255 * (p.glassSpecPeak or (dark and 0.38 or 0.45)) + 0.5)),
		spec_floor = p.glassSpecFloor or (dark and 0.06 or 0.08),
		shade = Color.pack(0, 0, 0, floor(255 * (p.glassInnerShade or (dark and 0.10 or 0.06)) + 0.5)),
		-- the palette and Activity (a split rim): 0.10 in both modes, so a light surface's
		-- lower and right lip read as a curved edge, not a flat band
		split_shade = Color.pack(0, 0, 0, floor(255 * (p.glassSplitShade or p.glassInnerShade or 0.10) + 0.5)),
		-- frosted and live glass carry text: the lit result's luminance stays at most
		-- lum_max and at least lum_min, so its labels keep their contrast (dark: at most
		-- 0.0622; light: at least 0.62, and a tooltip's body at most 0.86 so it reads as
		-- glass, not a white chip)
		lum_max = dark and (p.glassLumMax or 0.0622) or 1,
		lum_min = dark and 0 or (p.glassLumMin or 0.62),
		frost_max = dark and (p.glassLumMax or 0.0622) or (p.glassFrostLumMax or 0.86),
		frost = Color.alpha(col(p.glassFloatingTint, p.layer03), p.glassFrostAlpha or (dark and 0.55 or 0.32)),
		-- a tooltip's shadow: lighter in the light mode, so the frost does not read as a chip
		frost_shadow = Color.pack(0, 0, 0, floor(255 * (p.glassFrostShadowAlpha
			or (dark and (p.glassShadowAlpha or 0.32) or 0.12)) + 0.5)),
		live = Color.alpha(col(p.glassChromeTint, p.layer01), dark and M.LENS.live.tint or M.LIGHT_ART.tint),
		-- the sheet over a reactive background: its own colour over the blurred scene, the
		-- result bounded like frosted glass so its text keeps 4.5:1 over any frame of it
		veil = Color.alpha(col(p.glassVeilTint, p.layer02), p.glassVeilAlpha or (dark and 0.84 or 0.80)),
		veil_max = dark and (p.glassVeilLumMax or 0.0622) or 1,
		veil_min = dark and 0 or (p.glassVeilLumMin or 0.62),
		art = dark and M._ART_STEPS or M._LIGHT_ART_STEPS,
	}
end

-- The other mode's backdrop is loaded PREWARM s after this one, in an idle frame, so the
-- first light/dark switch decodes and uploads nothing (it cost that switch 20-30 ms).
M.PREWARM = 1.5
local function textures(dc, p, quiet)
	local B = dc.B
	if not cache or cache.B ~= B then release(); cache = { B = B, by_key = {} } end
	local key = p.glassBackdrop or ("flat:" .. tostring(p.bg))
	local c = cache.by_key[key]
	if not c then
		c = { looks = looks(p) }
		cache.by_key[key] = c
		if not quiet and cache.prewarm == nil then
			local R = package.loaded["core.imgui.Runtime"]
			if R and R.now and R.wakeAt then
				cache.prewarm = R.now() + M.PREWARM
				R.wakeAt(cache.prewarm)
			else
				cache.prewarm = false
			end
		end
		if B.texture then
			local sharp, sw, sh, blur, bw, bh
			if p.glassBackdrop then
				sharp, sw, sh = M._load_png(p.glassBackdrop .. ".png")
				blur, bw, bh = M._load_png(p.glassBackdrop .. "-blur.png")
			end
			if not (sharp and blur) then sharp, sw, sh = flat_pixels(p); blur, bw, bh = sharp, sw, sh end
			local ok, a, b = pcall(function() return B.texture(sharp, sw, sh), B.texture(blur, bw, bh) end)
			if ok and a and b then
				c.sharp, c.blur, c.sw, c.sh, c.bw, c.bh = a, b, sw, sh, bw, bh
				c.bytes = (sw * sh + bw * bh) * 4
			end
			M.generations = (M.generations or 0) + 1
		end
	end
	if cache.shadow == nil then
		cache.shadow = false
		local px, w, h = M._load_png("shadow.png")
		if px and B.texture then
			local ok, id = pcall(B.texture, px, w, h)
			if ok and id then cache.shadow, cache.shadow_bytes = id, w * h * 4 end
		end
	end
	return c
end

-- Once, at idle after the first backdrop loaded: the current theme's other mode's backdrop.
local function prewarm(dc)
	local due = cache and cache.prewarm
	if not due then return end
	local R = package.loaded["core.imgui.Runtime"]
	if not (R and R.now) or R.now() < due then return end
	cache.prewarm = false
	local manager = Reactor.themeManager()
	local current = manager and manager.current and manager:current()
	local other = current and manager.counterpart and manager:counterpart(current)
	local twin = other and manager.themeById and manager:themeById(other)
	local p = twin and twin.palette and twin:palette()
	if p and p.glass and p.glassBackdrop then textures(dc, p, true) end
end
M._prewarm = prewarm

-- "Cover" mapping, anchored top-left: window pixel (x, y) -> texture UV.
local function uv(dc, c, x1, y1, x2, y2, wide, tall)
	local W, H = dc.window_w or 1920, dc.window_h or 1080
	local s = max(W / wide, H / tall)
	local kx, ky = 1 / (wide * s), 1 / (tall * s)
	return x1 * kx, y1 * ky, x2 * kx, y2 * ky
end

-- The softened backdrop under a surface, in one rounded image when the backend can.
local function sample(dc, c, tex, x, y, w, h, radius, refract)
	local ax, ay = x + dc.ox, y + dc.oy
	local tw, th = c.sw, c.sh
	if tex == c.blur then tw, th = c.bw, c.bh end
	local i = refract and min(REFRACT, w / 8, h / 8) or 0
	local u1, v1, u2, v2 = uv(dc, c, ax + i, ay + i, ax + w - i, ay + h - i, tw, th)
	local tint = dc:_color(0xFFFFFFFF)
	if dc.B.image_rounded_uv then
		dc:_emit("image_rounded_uv", tex, ax, ay, ax + w, ay + h, u1, v1, u2, v2, tint, radius, 0)
		return
	end
	-- Older backends: square image strips that follow the rounded contour.
	local rad = min(radius, w / 2, h / 2)
	local du, dv = (u2 - u1) / w, (v2 - v1) / h
	local function strip(l, t, r, b)
		dc:_emit("image", tex, ax + l, ay + t, ax + r, ay + b, u1 + l * du, v1 + t * dv, u1 + r * du, v1 + b * dv, tint)
	end
	if rad > 0 then
		for row = 0, ceil(rad) - 1 do
			local inset = rad - math.sqrt(max(0, rad * rad - (rad - row - .5) ^ 2))
			strip(inset, row, w - inset, row + 1)
			strip(inset, h - row - 1, w - inset, h - row)
		end
		strip(0, ceil(rad), w, h - ceil(rad))
	else
		strip(0, 0, w, h)
	end
end

-- The bevel: one upper-left highlight fading to the far corner, one lower inner shade.
-- BEVEL is how far the baked sample softens inside the rim; RIM_WIDTH the rim line itself,
-- as thin as the shader's 1.2 px lobe so WARP's edge matches the hardware one.
local BEVEL, RIM_WIDTH = 2, 1.2
-- Hover lifts the highlight by up to 10 percentage points at its peak.
local HOVER_LIFT = 0.10
local function rim(dc, look, x, y, w, h, radius, lift)
	local base = look.rim_hi
	if lift and lift > 0 then
		local r, g, b, a = Color.unpack(base)
		base = Color.pack(r, g, b, min(255, a + 255 * HOVER_LIFT * lift))
	end
	local hi, lo, inner = dc:_color(base), dc:_color(look.rim_lo), dc:_color(look.rim_inner)
	if dc.B.rim then
		local ax, ay = x + dc.ox, y + dc.oy
		dc:_emit("rim", ax, ay, ax + w, ay + h, radius, hi, lo, inner, 0, RIM_WIDTH)
		return
	end
	dc:rect(x, y, w, h, lo, shapes[radius])
	dc:line(x + radius, y + 0.5, x + w - radius, y + 0.5, hi)
end

local function shadow(dc, look, x, y, w, h, col)
	local tex = cache and cache.shadow
	if not (tex and dc.B.image_nine) then return end
	local ax, ay = x + dc.ox - SHADOW_PAD, y + dc.oy - SHADOW_PAD + SHADOW_OFFSET
	local b = SHADOW_BORDER / SHADOW_TEX
	dc:_emit("image_nine", tex, ax, ay, ax + w + 2 * SHADOW_PAD, ay + h + 2 * SHADOW_PAD,
		SHADOW_BORDER, SHADOW_BORDER, b, b, dc:_color(col or look.shadow))
end

-- The floating entrance: seconds to fade in, and pixels of lift. A borderless glass
-- dialog's window reaches CLEARANCE px past it for the shadow (6 px drop, 18 px falloff).
M.ENTER, M.LIFT, M.CLEARANCE = 0.15, 4, 24
-- The rim's hover easing.
M.RIM_EASE = 0.11

local function motion_on()
	local manager = Reactor.themeManager()
	local director = manager and manager._motion
	return director and director:enabled(), director
end

--- Ease `state`'s rim toward hovered (`on`) over 110 ms; returns 0..1. Instant without
-- motion; asks for frames only while it moves.
function M.ease(state, on)
	local R = package.loaded["core.imgui.Runtime"]
	local target = on and 1 or 0
	local moving, director = motion_on()
	if not (R and moving) then state.rim_k = target; return target end
	local now = R.now()
	if state.rim_on == nil then
		state.rim_on, state.rim_from, state.rim_at = on, target, now
	elseif state.rim_on ~= on then
		state.rim_on, state.rim_from, state.rim_at = on, state.rim_k or (1 - target), now
	end
	local t = min(1, (now - state.rim_at) / (M.RIM_EASE * (director._scale or 1)))
	local k = state.rim_from + (target - state.rim_from) * t
	if t < 1 then R.animate() end
	state.rim_k = k
	return k
end

--- Floating glass opens with a 150 ms fade and a 4 px lift; instant without motion.
-- `state.opened` is set on the first call; returns the eased progress 0..1.
function M.entrance(state)
	local R = package.loaded["core.imgui.Runtime"]
	if not R then return 1 end
	local now = R.now()
	state.opened = state.opened or now
	local manager = Reactor.themeManager()
	local director = manager and manager._motion
	if not (director and director:enabled()) then return 1 end
	local t = (now - state.opened) / (M.ENTER * (director._scale or 1))
	if t >= 1 then return 1 end
	R.animate()
	return 1 - (1 - max(0, t)) ^ 3
end

-- The rail's two caps: one round the tabs and the "+" that follows them, one round the
-- chevron at its foot; the bare backdrop shows between them.
local CAP_PAD = 4
local function caps(dc, el, x, y, w, h)
	local ok, tabs = pcall(require, "core.imgui.widgets.flattabs")
	local rects = ok and el and tabs.extraRects and tabs.extraRects(el) or {}
	local add, foot = rects[1], rects[2]
	if not (add and foot) then return { { x, y, w, h } } end
	local top_end = add[2] + add[4] + CAP_PAD
	local foot_start = foot[2] - CAP_PAD
	if foot_start - top_end < 24 then return { { x, y, w, h } } end
	return { { x + CAP_PAD, y + CAP_PAD, w - 2 * CAP_PAD, top_end - y - CAP_PAD },
		{ x + CAP_PAD, foot_start, w - 2 * CAP_PAD, y + h - CAP_PAD - foot_start } }
end
M._caps = caps

-- What lies under a floating surface, from the frame copy (the main window's background
-- layer this frame): pulled 2 px inward across the bevel so it bends there, and softened
-- by four diagonal taps 2 px out (about 4 px) across the rest, under a heavier tint than
-- the shader's (BAKED_LIP_TINT), so text under the lip is a smear, not glyphs. Off when
-- the backend has no copy.
local SOFT = 2
-- The baked lip's tint, as a multiple of the shader's (which blurs what it tints).
M.BAKED_LIP_TINT = 2.6
local function underneath(dc, x, y, w, h, r)
	local B = dc.B
	if dc.rec or not (B.window and B.image_rounded_uv) then return end
	local id, fw, fh = B.window("frame_copy")
	if type(id) ~= "number" or not fw or fw <= 0 or fh <= 0 then return end
	local ax, ay = x + dc.ox, y + dc.oy
	local white = dc:_color(0xFFFFFFFF)
	local i = REFRACT
	dc:_emit("image_rounded_uv", id, ax, ay, ax + w, ay + h,
		(ax + i) / fw, (ay + i) / fh, (ax + w - i) / fw, (ay + h - i) / fh, white, r, 0)
	local b = BEVEL
	for k = 1, 4 do
		local dx, dy = (k % 2 == 1) and -SOFT or SOFT, k <= 2 and -SOFT or SOFT
		dc:_emit("image_rounded_uv", id, ax + b, ay + b, ax + w - b, ay + h - b,
			(ax + b + dx) / fw, (ay + b + dy) / fh, (ax + w - b + dx) / fw, (ay + h - b + dy) / fh,
			Color.alpha(white, 1 / k), max(0, r - b), 0)
	end
end

-- Glass surfaces drawn this frame (absolute rects, flat), for wantsPointer.
local lit, lit_n, pointer_near = {}, 0, false
local function lit_begin(dc)
	if dc.glass_frame then return end
	dc.glass_frame = true
	lit_n = 0
end

local BASE_ANGLE = math.atan2(-1, -1)   -- the light, from the upper left
local function wrap(a)
	while a > math.pi do a = a - 2 * math.pi end
	while a < -math.pi do a = a + 2 * math.pi end
	return a
end

--- The light's turn (radians) for a surface at (ax, ay, w, h): toward the pointer while it
-- is over or within LIGHT.range px of it, eased over RIM_EASE; 0 at rest, without a
-- `state` and with reduced motion.
function M.light(dc, state, ax, ay, w, h)
	lit_begin(dc)
	lit[lit_n + 1], lit[lit_n + 2], lit[lit_n + 3], lit[lit_n + 4] = ax, ay, ax + w, ay + h
	lit_n = lit_n + 4
	if not state then return 0 end
	local R = package.loaded["core.imgui.Runtime"]
	local moving, director = motion_on()
	if not (R and R.pointer and moving) then state.light_k, state.light_to = nil, nil; return 0 end
	local px, py, inside = R.pointer()
	local target = 0
	if inside and px then
		local dx, dy = max(ax - px, 0, px - ax - w), max(ay - py, 0, py - ay - h)
		local range = M.LIGHT.range
		if dx * dx + dy * dy <= range * range then
			local turn = M.LIGHT.turn
			target = min(turn, max(-turn, wrap(math.atan2(py - ay - h / 2, px - ax - w / 2) - BASE_ANGLE)))
		end
	end
	local now = R.now()
	if state.light_to == nil then state.light_to, state.light_from, state.light_at = target, target, now end
	if target ~= state.light_to then
		state.light_from, state.light_to, state.light_at = state.light_k or 0, target, now
	end
	local t = min(1, (now - state.light_at) / (M.RIM_EASE * (director._scale or 1)))
	local e = t * t * (3 - 2 * t)
	if t < 1 then R.animate() end
	state.light_k = state.light_from + (state.light_to - state.light_from) * e
	return state.light_k
end

--- Should the pointer moving to (x, y) redraw? While it is (or just was) near glass, whose
-- light follows it; never with reduced motion.
function M.wantsPointer(x, y, inside)
	if not motion_on() then return false end
	local near, range = false, M.LIGHT.range
	if inside then
		for i = 1, lit_n, 4 do
			if x >= lit[i] - range and x <= lit[i + 2] + range and y >= lit[i + 1] - range and y <= lit[i + 3] + range then
				near = true; break
			end
		end
	end
	local was = pointer_near
	pointer_near = near
	return near or was
end

-- The transport's nearest artwork (recorded by the runtime from its children last frame),
-- drawn under it reaching ART_REACH px past the artwork: its edge texels stretch to fill.
-- It is drawn as nested rects, outermost first, each over the last: the poster's edge
-- texels whole to ART_HOLD px, then four equal steps down to nothing at ART_REACH (the
-- transport's strong blur smooths the steps). ART_STEPS: each step's reach and the alpha
-- of its layer, so the coverage left there is 1/8, 3/8, 5/8, 7/8, then whole (the light
-- mode's steps: the same shares of 7/8, over 24 px).
local CORNERS_LEFT, CORNERS_RIGHT, CORNERS_NONE = 16 + 64, 32 + 128, 256
-- `peak`: the artwork's own coverage where it is whole (the light mode's 7/8)
local function art_steps(hold, fade, peak)
	local steps, prev = {}, 0
	for i = 4, 1, -1 do
		local cover = (2 * (4 - i) + 1) / 8 * peak
		steps[#steps + 1] = { hold + fade * i / 4, (cover - prev) / (1 - prev) }
		prev = cover
	end
	steps[#steps + 1] = { hold, (peak - prev) / (1 - prev) }
	return steps
end
local ART_STEPS = art_steps(M.ART_HOLD, M.ART_FADE, 1)
M._ART_STEPS = ART_STEPS
M._LIGHT_ART_STEPS = art_steps(M.LIGHT_ART.hold, M.LIGHT_ART.fade, M.LIGHT_ART.share / (1 - M.LIGHT_ART.tint))
local function extend_art(dc, art, ax, ay, w, h, r, steps)
	if not (art and art.tex and art.w > 0 and art.h > 0 and dc.B.image_rounded_uv) then return end
	for _, step in ipairs(steps or ART_STEPS) do
		local reach = step[1]
		local x1, y1 = max(ax, art.x - reach), max(ay, art.y - reach)
		local x2, y2 = min(ax + w, art.x + art.w + reach), min(ay + h, art.y + art.h + reach)
		if x2 > x1 and y2 > y1 then
			local flags = 0
			if x1 < ax + r then flags = flags + CORNERS_LEFT end
			if x2 > ax + w - r then flags = flags + CORNERS_RIGHT end
			if flags == 0 then flags = CORNERS_NONE end
			dc:_emit("image_rounded_uv", art.tex, x1, y1, x2, y2,
				(x1 - art.x) / art.w, (y1 - art.y) / art.h, (x2 - art.x) / art.w, (y2 - art.y) / art.h,
				dc:_color(Color.alpha(0xFFFFFFFF, step[2])), r, flags)
		end
	end
end

--- Paint `kind` at (x, y, w, h) in the dc's local coordinates. `lip` sets a floating
-- surface's see-through edge (default the palette's `glassLip`), `lift` (0..1) the eased
-- hover on the rim's highlight. `state` (a table kept with the surface) eases its light;
-- `style` (its theme rule) may set `chroma`, `frost` (a tooltip) or `live` (the
-- transport). Native popups map the backdrop by their own window.
function M.paint(dc, x, y, w, h, kind, p, radius, el, lip, lift, state, style)
	p = p or Reactor.palette()
	if kind == "content" or kind == "chrome_content" or kind == "none" then return end
	if kind == "caps" then
		local subs = state and state.caps
		if state and not subs then subs = { {}, {} }; state.caps = subs end
		for i, r in ipairs(caps(dc, el, x, y, w, h)) do
			M.paint(dc, r[1], r[2], r[3], r[4], "chrome", p, min(radius or 14, r[3] / 2), nil, nil, lift, subs and subs[i])
		end
		return
	end
	if kind == "veil" then
		local Background = require("core.ui.Background")
		local sharp, blur, ku, kv = Background.textures(dc.B)
		if not (enabled and p.glass and gpu(dc) and sharp) then kind = "card" else
			local c = textures(dc, p)
			local look = c.looks
			local r = radius or p.radiusSheet or 14
			local ax, ay = x + dc.ox, y + dc.oy
			local lens = M.LENS.veil
			-- `glassVeilClear`: clear tinted glass, the sharp scene in its body (stars stay
			-- points behind the panel); otherwise frosted, the blurred scene
			if p.glassVeilClear then blur = sharp end
			dc:_emit("glass", ax, ay, ax + w, ay + h, r, 1, look.veil, look.spec, look.shade,
				min(lens.band, w / 2, h / 2), lens.thickness, 0, dc:_color(0xFFFFFFFF), sharp, blur, ku, kv,
				0, 0, lens.chroma, 0, look.veil_max, look.veil_min, look.spec_floor, -1, 0)
			if p.glassVeilRim then dc:rect(x, y, w, h, p.glassVeilRim, fine_shapes[r]) end
			return
		end
	end
	if kind == "card" then
		local r = radius or p.radiusSheet or 14
		dc:fill(x, y, w, h, p.layer02, fine_shapes[r])
		local c = enabled and p.glass and textures(dc, p)
		dc:rect(x, y, w, h, c and c.looks.card_rim or (p.glassDark and "255 255 255 15" or "0 0 0 15"), fine_shapes[r])
		return
	end
	local floating = kind == "floating"
	local solid = kind == "floor" and p.bg or (floating and (p.glassTextWell or p.layer03 or p.layer02) or p.layer01)
	if not solid then return end
	local c = enabled and p.glass and textures(dc, p)
	if c and kind == "floor" then prewarm(dc) end
	local r = radius or (floating and (p.radiusFloating or 16) or 0)
	r = min(r, w / 2, h / 2)
	local tex = c and (kind == "floor" and c.sharp or c.blur)
	if not tex then
		-- Glass off (or no image): the same layout with solid fills.
		dc:fill(x, y, w, h, solid, shapes[r])
		if kind ~= "floor" then
			dc:rect(x, y, w, h, p.glassDark and "255 255 255 20" or "0 0 0 25", shapes[r])
		end
		return
	end
	if kind == "floor" then
		local Background = require("core.ui.Background")
		if Background.of(p) and Background.floor(dc, x, y, w, h, p, gpu(dc)) then
			-- the frame's tint; while a mode switch's sky is still on its way it holds as much
			-- more as the labels on it need (Background.frameAlpha)
			local a = Background.frameAlpha(p)
			if a > 0 then
				dc:fill(x, y, w, h, Color.alpha(Color.parse(p.glassFrameTint or p.bg), a))
			end
			return
		end
		sample(dc, c, tex, x, y, w, h, 0, false); return
	end
	local look = c.looks
	local live = gpu(dc)
	if floating then
		-- A text-free lip that shows what is underneath (bent at the bevel, softened
		-- inside it) under a light tint, round an opaque text well whose last two pixels
		-- blend into the lip.
		local l = min(lip or p.glassLip or 8, floor(w / 4), floor(h / 4))
		local frost = live and style and style.frost
		-- a surface that splits its rim (palette, Activity) keeps a sharper rim and the light blur
		local edge = (style and style.chroma) and M.LENS.split or (frost and M.LENS.frost or M.LENS.floating)
		-- the shader's copy of what is under it comes first: it never samples its own shadow
		if live and dc.B.glass_copy then
			local ax, ay = x + dc.ox, y + dc.oy
			dc:_emit("glass_copy", ax, ay, ax + w, ay + h, frost and 3 or 0, frost and 0 or l, r, edge.soft)
		end
		shadow(dc, look, x, y, w, h, frost and look.frost_shadow or nil)
		if live then
			-- the shader: the live frame under it, bent across the lip, blurred, tinted, lit,
			-- easing into the opaque well over the lip's last 6 px (a tooltip: no well)
			local ax, ay = x + dc.ox, y + dc.oy
			local lens = frost and M.LENS.frost or M.LENS.floating
			local angle = M.light(dc, state, ax, ay, w, h)
			local chroma = style and style.chroma or lens.chroma
			if frost then
				dc:_emit("glass", ax, ay, ax + w, ay + h, r, 3, look.frost, look.spec, look.shade,
					lens.band, lens.thickness, lift or 0, dc:_color(0xFFFFFFFF), 0, 0, 0, 0,
					0, 0, chroma, angle, look.frost_max, look.lum_min, look.spec_floor, edge.rim_blur, edge.blur_depth)
				return
			end
			dc:_emit("glass", ax, ay, ax + w, ay + h, r, 0, look.floating, look.spec,
				(style and style.chroma) and look.split_shade or look.shade, min(lens.band, l), min(lens.thickness, l), lift or 0, dc:_color(0xFFFFFFFF), 0, 0, 0, 0,
				look.well, l, chroma, angle, 1, 0, look.spec_floor, edge.rim_blur, edge.blur_depth, edge.soft,
				lens.well_ease)
			dc:fill(x + l, y + l, w - 2 * l, h - 2 * l, look.well, shapes[max(0, r - l)])
			return
		else
			underneath(dc, x, y, w, h, r)
			dc:fill(x, y, w, h, look.floating_baked, shapes[r])
		end
		if l >= 3 then
			for k = 2, 1, -1 do
				local e = l - k
				dc:fill(x + e, y + e, w - 2 * e, h - 2 * e, look.well_feather[3 - k], shapes[max(0, r - e)])
			end
		end
		dc:fill(x + l, y + l, w - 2 * l, h - 2 * l, look.well, shapes[max(0, r - l)])
	elseif live then
		-- chrome lies on the floor: the shader samples its images (no copy of the frame),
		-- mapped px -> uv as sample() maps them
		local ax, ay = x + dc.ox, y + dc.oy
		local lens = M.LENS.chrome
		local band = min(lens.band, w / 2, h / 2)
		local angle = M.light(dc, state, ax, ay, w, h)
		if style and style.live then
			-- the transport: the nearest artwork extended under it, copied with what lies
			-- there, strongly blurred, mostly tinted and bounded for its labels
			lens = M.LENS.live
			extend_art(dc, state and state.glass_art, ax, ay, w, h, r, look.art)
			dc:_emit("glass", ax, ay, ax + w, ay + h, r, 2, look.live, look.spec, look.shade,
				min(lens.band, w / 2, h / 2), lens.thickness, lift or 0, dc:_color(0xFFFFFFFF), 0, 0, 0, 0,
				0, 0, lens.chroma, angle, look.lum_max, look.lum_min, look.spec_floor, lens.rim_blur, lens.blur_depth)
			return
		end
		local _, _, ku, kv = uv(dc, c, 0, 0, 1, 1, c.sw, c.sh)
		local sharp, blur = c.sharp, c.blur
		local Background = require("core.ui.Background")
		local ss, sb, sku, skv = Background.textures(dc.B)
		if ss then sharp, blur, ku, kv = ss, sb, sku, skv end
		-- while a mode switch's sky has not reached the UI's mode, chrome bounds its
		-- luminance for its labels as the transport does
		local hi, lo = 1, 0
		if ss and Background.lag() > 0 then hi, lo = look.lum_max, look.lum_min end
		dc:_emit("glass", ax, ay, ax + w, ay + h, r, 1, look.chrome, look.spec, look.shade,
			band, min(lens.thickness, band), lift or 0, dc:_color(0xFFFFFFFF), sharp, blur, ku, kv,
			0, 0, lens.chroma, angle, hi, lo, look.spec_floor, -1, 0)
		return -- the shader drew the rim
	else
		sample(dc, c, tex, x, y, w, h, r, true)
		dc:fill(x, y, w, h, look.chrome, shapes[r])
	end
	if not live then rim(dc, look, x, y, w, h, r, lift) end
end

-- Resolve flags once per theme, rather than allocating rules per widget/frame.
function M.material(el, st)
	local manager = Reactor.themeManager()
	local active = manager and manager:activeTheme()
	if active ~= theme then
		-- Textures are cached per mode, so a theme switch keeps them for the way back.
		theme = active; rules = active and active:rules() or {}
		local p = active and active:palette() or {}
		floating_dialog = { bg = rules.dialog and rules.dialog.bg, glass = "floating", radius = p.radiusFloating or 16 }
	end
	if not rules then return end
	local p = active and active:palette()
	if not p or not p.glass then return end
	local role = st.attrs.THEMEROLE or st.classname
	local r = rules[role]
	if r and r.glass == "floor" and st.attrs.PARENTDIALOG then r = floating_dialog end
	if r and r.glass then return r, p end
end
return M
