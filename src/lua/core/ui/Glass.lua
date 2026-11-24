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
--   content / chrome_content / none   children of the above: nothing (the parent's glass
--             shows; the runtime skips their own fill of the material colour)
--
-- On a hardware device (B.glass_ready(), asked once per frame) chrome and floating glass are
-- a live shader instead (lunar_glass_d3d11.inc): each surface is one `glass` call that
-- refracts and blurs what is actually under it this frame, with the rim's specular and
-- inner shade, and the same tints; the floating shadow and the opaque text well stay as
-- below. On WARP, an SDL host, or with hardware acceleration off, the baked path below is
-- used unchanged. The floor (the backdrop the glass refracts) and the matte card are the
-- same on both paths.
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

-- The shader's lens: the band (px in from the rim) it bends over, and how far it pulls the
-- view in at the rim. A floating surface bends across its lip, so the band follows it.
M.LENS = { floating = 0.75, chrome = { band = 8, thickness = 4 } }

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
		well = col(p.glassTextWell, p.layer03),
		-- the well's last two pixels blend into the lip instead of ending in an edge
		well_feather = { Color.alpha(col(p.glassTextWell, p.layer03), 0.35), Color.alpha(col(p.glassTextWell, p.layer03), 0.5) },
		rim_hi = col(p.glassRimHi, dark and "255 255 255 115" or "255 255 255 153"),
		rim_lo = col(p.glassRimLo, dark and "255 255 255 20" or "255 255 255 26"),
		rim_inner = col(p.glassRimInner, dark and "0 0 0 36" or "0 0 0 23"),
		shadow = Color.pack(0, 0, 0, floor(255 * (p.glassShadowAlpha or (dark and 0.32 or 0.17)) + 0.5)),
		card_rim = col(p.glassCardRim, dark and "255 255 255 15" or "0 0 0 15"),
	}
end

local function textures(dc, p)
	local B = dc.B
	if not cache or cache.B ~= B then release(); cache = { B = B, by_key = {} } end
	local key = p.glassBackdrop or ("flat:" .. tostring(p.bg))
	local c = cache.by_key[key]
	if not c then
		c = { looks = looks(p) }
		cache.by_key[key] = c
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
local BEVEL = 2
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
		dc:_emit("rim", ax, ay, ax + w, ay + h, radius, hi, lo, inner, 0, BEVEL)
		return
	end
	dc:rect(x, y, w, h, lo, shapes[radius])
	dc:line(x + radius, y + 0.5, x + w - radius, y + 0.5, hi)
end

local function shadow(dc, look, x, y, w, h)
	local tex = cache and cache.shadow
	if not (tex and dc.B.image_nine) then return end
	local ax, ay = x + dc.ox - SHADOW_PAD, y + dc.oy - SHADOW_PAD + SHADOW_OFFSET
	local b = SHADOW_BORDER / SHADOW_TEX
	dc:_emit("image_nine", tex, ax, ay, ax + w + 2 * SHADOW_PAD, ay + h + 2 * SHADOW_PAD,
		SHADOW_BORDER, SHADOW_BORDER, b, b, dc:_color(look.shadow))
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
-- by four half-pixel taps (about 1.5 px) across the rest. Off when the backend has no copy.
local SOFT = 0.75
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

--- Paint `kind` at (x, y, w, h) in the dc's local coordinates. `lip` sets a floating
-- surface's see-through edge (default the palette's `glassLip`), `lift` (0..1) the eased
-- hover on the rim's highlight. Native popups map the backdrop by their own window.
function M.paint(dc, x, y, w, h, kind, p, radius, el, lip, lift)
	p = p or Reactor.palette()
	if kind == "content" or kind == "chrome_content" or kind == "none" then return end
	if kind == "caps" then
		for _, r in ipairs(caps(dc, el, x, y, w, h)) do
			M.paint(dc, r[1], r[2], r[3], r[4], "chrome", p, min(radius or 14, r[3] / 2), nil, nil, lift)
		end
		return
	end
	if kind == "card" then
		local r = radius or p.radiusSheet or 14
		dc:fill(x, y, w, h, p.layer02, shapes[r])
		local c = enabled and p.glass and textures(dc, p)
		dc:rect(x, y, w, h, c and c.looks.card_rim or (p.glassDark and "255 255 255 15" or "0 0 0 15"), shapes[r])
		return
	end
	local floating = kind == "floating"
	local solid = kind == "floor" and p.bg or (floating and (p.glassTextWell or p.layer03 or p.layer02) or p.layer01)
	if not solid then return end
	local c = enabled and p.glass and textures(dc, p)
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
	if kind == "floor" then sample(dc, c, tex, x, y, w, h, 0, false); return end
	local look = c.looks
	local live = gpu(dc)
	if floating then
		-- A text-free lip that shows what is underneath (bent at the bevel, softened
		-- inside it) under a light tint, round an opaque text well whose last two pixels
		-- blend into the lip.
		shadow(dc, look, x, y, w, h)
		local l = min(lip or p.glassLip or 8, floor(w / 4), floor(h / 4))
		if live then
			-- the shader: the live frame under it, bent across the lip, blurred, tinted, lit
			local ax, ay = x + dc.ox, y + dc.oy
			dc:_emit("glass", ax, ay, ax + w, ay + h, r, 0, look.floating, look.rim_hi, look.rim_inner,
				max(l, 3), max(l, 3) * M.LENS.floating, lift or 0, dc:_color(0xFFFFFFFF))
		else
			underneath(dc, x, y, w, h, r)
			dc:fill(x, y, w, h, look.floating, shapes[r])
		end
		if l >= 3 then
			for k = 2, 1, -1 do
				local e = l - k
				dc:fill(x + e, y + e, w - 2 * e, h - 2 * e, look.well_feather[3 - k], shapes[max(0, r - e)])
			end
		end
		dc:fill(x + l, y + l, w - 2 * l, h - 2 * l, look.well, shapes[max(0, r - l)])
	elseif live then
		local ax, ay = x + dc.ox, y + dc.oy
		local lens = M.LENS.chrome
		local band = min(lens.band, w / 2, h / 2)
		dc:_emit("glass", ax, ay, ax + w, ay + h, r, 1, look.chrome, look.rim_hi, look.rim_inner,
			band, min(lens.thickness, band), lift or 0, dc:_color(0xFFFFFFFF))
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
