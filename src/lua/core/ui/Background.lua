--- Reactive backgrounds: a theme's declared background layers, bound to signals.
--
-- A palette may carry `background = { id = ..., layers = { ... } }` (see docs/theming.md,
-- "Reactive backgrounds"). Each layer is a gradient fill, an SVG element, a procedural
-- star field or a video, and any of its properties (position, offset, scale, rotation,
-- opacity, tint) may be bound to a signal instead of a constant:
--
--   time        seconds since the scene started (0 while static)
--   clock       time of day, 0..1 (changes once a minute)
--   mode        0 dark .. 1 light, eased while the theme switches between the two
--   mouse_x/y   the pointer, -1..1 across the window (0 while static or away)
--   width/height  the window, px
--   rail        the sidebar, 0 collapsed .. 1 extended (follows its motion)
--   rail_settled  0 .. 1 once the sidebar has finished extending (0 as it starts to collapse)
--   rail_room   px free below the sidebar's entries (read from the rail's layout)
--   fullscreen  0 or 1
--
-- More signals are one call: `Scene.signal(name, { read = function(ctx) ... end })`, or a
-- pushed value, `Scene.set(name, value)`.
--
-- Efficiency: each layer knows the signals it reads. The scene is drawn again only when
-- one of those changed: an idle window with a static scene draws nothing; a time-bound
-- layer redraws at the scene's `fps` (default 24) and no faster; a mouse-bound one only
-- when the pointer moved. On a device with a scene target (D3D11) the layers are drawn
-- into it, the floor and chrome glass sample it, and a frame whose only change is the
-- scene is presented without a frame of the UI (`Scene.tick`, from the runtime's idle
-- loop). SVGs are rasterized and uploaded once per size; nothing uploads after warm-up.
-- With motion off, on WARP or with hardware acceleration off, the scene is static: time
-- and the pointer read 0, so it is drawn once per window size, mode or rail change.
-- @module core.ui.Background
local Color = require("core.imgui.Color")
local M = {}

local floor, max, min, sin, cos, pi = math.floor, math.max, math.min, math.sin, math.cos, math.pi

M.FPS = 24          -- the default cap for time-bound redraws
M.MODE_EASE = 0.6   -- s: the sky's dark/light change (scaled like other motion)
M.MODE_DELAY = 0.08 -- s: it starts this long after the UI has switched
M.ASSET_DIR = nil   -- where `file =` SVGs live (assets/scene next to the exe)

-- Signals ------------------------------------------------------------------------------
local signals, pushed = {}, {}
--- Register a signal: `def.read(ctx)` returns its number now. `ctx`: { now, w, h, static }.
function M.signal(name, def) signals[name] = def end
--- Push a signal's value (the rail, fullscreen, or a theme's own); a frame follows when a
-- layer reads it.
function M.set(name, value)
	if pushed[name] == value then return end
	pushed[name] = value
	local R = package.loaded["core.imgui.Runtime"]
	if M._deps and M._deps[name] and R and R.wakeAt and R.now then R.wakeAt(R.now()) end
end
function M.get(name) return pushed[name] end

-- `tail`: an ease ran and no full frame has been drawn since it ended (the frame's lag
-- tint and the veil's bounds follow the sky only in full frames)
local mode = { value = nil, from = 0, to = 0, at = 0, dur = 0, tail = false }
local t0
M.signal("time", { animated = true, read = function(ctx)
	if ctx.static then return 0 end
	t0 = t0 or ctx.now
	return ctx.now - t0
end })
M.signal("clock", { read = function()
	local t = os.date("*t")
	return (t.hour * 60 + t.min) / 1440
end })
M.signal("mode", { read = function(ctx)
	if mode.dur <= 0 or ctx.now >= mode.at + mode.dur then return mode.to end
	if ctx.now <= mode.at then return mode.from end
	local t = (ctx.now - mode.at) / mode.dur
	t = t * t * (3 - 2 * t)
	return mode.from + (mode.to - mode.from) * t
end })
M.signal("mouse_x", { read = function(ctx) return ctx.static and 0 or ctx.mx or 0 end })
M.signal("mouse_y", { read = function(ctx) return ctx.static and 0 or ctx.my or 0 end })
M.signal("width", { read = function(ctx) return ctx.w end })
M.signal("height", { read = function(ctx) return ctx.h end })
M.signal("rail", { read = function() return pushed.rail or 0 end })
M.signal("rail_settled", { read = function() return pushed.rail_settled or 0 end })
M.signal("fullscreen", { read = function() return pushed.fullscreen or 0 end })

-- Values -------------------------------------------------------------------------------
-- A colour as { r, g, b, a } 0..255.
local function rgba(v)
	local c = Color.parse(v)
	if not c then return nil end
	local r, g, b, a = Color.unpack(c)
	return { r, g, b, a }
end
local function lerp(a, b, t)
	if type(a) == "table" then
		return { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t, a[4] + (b[4] - a[4]) * t }
	end
	return a + (b - a) * t
end
local function constant(v)
	if type(v) == "string" then
		local c = rgba(v)
		if c then return c end
	end
	return v
end

--- Compile a property's value: a constant, a binding table or a function. Returns
-- `fn(s) -> value` and adds the signals it reads to `deps`.
-- Bindings (all take `signal`):
--   { signal, from, to [, range = { lo, hi }] [, ease = "smooth"] }  interpolate
--   { signal, stops = { { at, value }, ... } [, ease] }               piecewise
--   { signal, wave = "sine"|"triangle", period, phase, min, max }      oscillate
--   { signal, scale [, offset] }                                       proportional
--   { signal, rate [, offset] [, wrap] }                               linear (degrees/s)
--   { add = { ... } } / { mul = { ... } }                              combine
-- A function value reads `s[name]`; its layer's `deps` lists the names (all if absent).
local function compile(v, deps)
	local tv = type(v)
	if tv == "function" then deps["*"] = true; return v end
	if tv ~= "table" or v[1] ~= nil and v.signal == nil and v.add == nil and v.mul == nil then
		local c = constant(v)
		return function() return c end
	end
	if v.add or v.mul then
		local parts = {}
		for i, e in ipairs(v.add or v.mul) do parts[i] = compile(e, deps) end
		local adding = v.add ~= nil
		return function(s)
			local acc = adding and 0 or 1
			for i = 1, #parts do
				if adding then acc = acc + parts[i](s) else acc = acc * parts[i](s) end
			end
			return acc
		end
	end
	local name = v.signal
	if not name then local c = constant(v); return function() return c end end
	deps[name] = true
	local smooth = v.ease == "smooth"
	if v.wave then
		local period, phase = v.period or 1, v.phase or 0
		local lo, hi = v.min or 0, v.max or 1
		local tri = v.wave == "triangle"
		return function(s)
			local x = (s[name] or 0) / period + phase
			local k
			if tri then x = x - floor(x); k = x < 0.5 and 2 * x or 2 - 2 * x
			else k = 0.5 - 0.5 * cos(2 * pi * x) end
			return lo + (hi - lo) * k
		end
	end
	if v.stops then
		local stops = {}
		for i, st in ipairs(v.stops) do stops[i] = { st[1], constant(st[2]) } end
		return function(s)
			local x = s[name] or 0
			if x <= stops[1][1] then return stops[1][2] end
			for i = 2, #stops do
				local a, b = stops[i - 1], stops[i]
				if x <= b[1] then
					local t = (x - a[1]) / max(1e-9, b[1] - a[1])
					if smooth then t = t * t * (3 - 2 * t) end
					return lerp(a[2], b[2], t)
				end
			end
			return stops[#stops][2]
		end
	end
	if v.from ~= nil then
		local a, b = constant(v.from), constant(v.to)
		local lo, hi = 0, 1
		if v.range then lo, hi = v.range[1], v.range[2] end
		return function(s)
			local t = ((s[name] or 0) - lo) / (hi - lo)
			t = t < 0 and 0 or (t > 1 and 1 or t)
			if smooth then t = t * t * (3 - 2 * t) end
			return lerp(a, b, t)
		end
	end
	if v.rate then
		local rate, off, wrap = v.rate, v.offset or 0, v.wrap
		return function(s)
			local x = off + (s[name] or 0) * rate
			if wrap then x = x % wrap end
			return x
		end
	end
	local scale, off = v.scale or 1, v.offset or 0
	return function(s) return off + (s[name] or 0) * scale end
end
M._compile = compile

-- Layers -------------------------------------------------------------------------------
local PROPS = { "x", "y", "dx", "dy", "scale", "rotation", "opacity", "tint", "top", "bottom", "parallax" }
local DEFAULTS = { x = 0.5, y = 0.5, dx = 0, dy = 0, scale = 1, rotation = 0, opacity = 1, tint = "#FFFFFF",
	top = "#000000", bottom = "#000000", parallax = 0 }

-- A deterministic generator, so a star field is the same every run.
local function lcg(seed)
	local state = seed % 2147483647
	if state <= 0 then state = state + 2147483646 end
	return function()
		state = state * 16807 % 2147483647
		return (state - 1) / 2147483646
	end
end

-- An svg layer's art: one source (`svg` inline or `file`), or a set chosen by a signal
-- (`svg = { signal = s, set = { ... } [, range = { lo, hi }] }`, every entry made when the
-- scene first shows). A video's art is its `poster` (an svg layer table), never its file.
local function art_of(def, kind, deps)
	local src = def.svg or def.file
	if kind == "video" then
		src = type(def.poster) == "table" and (def.poster.svg or def.poster.file) or nil
	end
	if type(src) == "table" and src.set then
		local set, name = src.set, src.signal
		local lo, hi = 0, 1
		if src.range then lo, hi = src.range[1], src.range[2] end
		if name then deps[name] = true end
		return set, function(s)
			local t = ((s[name] or 0) - lo) / (hi - lo)
			t = t < 0 and 0 or (t > 1 and 1 or t)
			return set[1 + floor(t * (#set - 1) + 0.5)]
		end
	end
	if src == nil then return {}, function() return nil end end
	return { src }, function() return src end
end

local function compile_layer(def)
	local layer = { def = def, kind = def.kind or ((def.svg or def.file) and "svg") or "fill", deps = {} }
	for _, k in ipairs(PROPS) do
		local v = def[k]
		if v == nil then v = DEFAULTS[k] end
		layer[k] = compile(v, layer.deps)
	end
	if def.deps then
		layer.deps["*"] = nil
		for _, name in ipairs(def.deps) do layer.deps[name] = true end
	end
	if layer.kind == "stars" then
		local rnd = lcg(def.seed or 7)
		local stars, n = {}, def.count or 120
		local smin, smax = (def.size or { 1, 2.5 })[1], (def.size or { 1, 2.5 })[2]
		local tw = def.twinkle or {}
		local share = tw.share or 0.5
		local pmin, pmax = (tw.period or { 3, 7 })[1], (tw.period or { 3, 7 })[2]
		local region = def.region or { 0, 0, 1, 1 }
		local colors = {}
		for i, c in ipairs(def.colors or { "#FFFFFF" }) do colors[i] = rgba(c) end
		for i = 1, n do
			local u, v = rnd(), rnd()
			local depth = rnd()
			local size = smin + (smax - smin) * (rnd() ^ 2.2)   -- mostly small, a few bright
			stars[i] = {
				u = region[1] + (region[3] - region[1]) * u, v = region[2] + (region[4] - region[2]) * v,
				depth = 0.25 + 0.75 * depth, r = size,
				base = 0.45 + 0.55 * rnd(),
				twinkles = rnd() < share, period = pmin + (pmax - pmin) * rnd(), phase = rnd(),
				color = colors[1 + floor(rnd() * #colors) % #colors],
			}
		end
		layer.stars, layer.amount = stars, tw.amount or 0
		-- `frame = { opacity, top, bottom, left }`: stars in those strips of the window (px;
		-- `left` may be bound) are capped at `opacity`, scaled down with the rest
		if def.frame then
			layer.frame_left = compile(def.frame.left or 0, layer.deps)
			layer.frame_cap = def.frame.opacity or 1
		end
		if layer.amount > 0 and share > 0 then layer.deps.time = true end
	end
	if layer.kind == "svg" or layer.kind == "video" then
		-- a video's poster is still: it reads only what its own properties read
		layer.arts, layer.art = art_of(def, layer.kind, layer.deps)
	end
	-- a parallax offset reads the pointer
	if def.parallax and def.parallax ~= 0 then layer.deps.mouse_x, layer.deps.mouse_y = true, true end
	-- `whole = true`: shown whole or not at all (M.cover)
	if def.whole and (layer.kind == "svg" or layer.kind == "video") then
		layer.whole = { from = 1, to = 1, at = 0, dur = 0, seen = false }
	end
	return layer
end

local compiled = setmetatable({}, { __mode = "k" })   -- background table -> compiled scene
local function scene_of(bg)
	local s = compiled[bg]
	if s then return s end
	s = { bg = bg, layers = {}, deps = {}, fps = bg.fps or M.FPS }
	for i, def in ipairs(bg.layers or {}) do
		local layer = compile_layer(def)
		s.layers[i] = layer
		for k in pairs(layer.deps) do s.deps[k] = true end
	end
	if s.deps["*"] then for k in pairs(signals) do s.deps[k] = true end end
	for _, layer in ipairs(s.layers) do if layer.whole then s.wholes = true end end
	compiled[bg] = s
	return s
end
M._scene_of = scene_of

-- Textures -----------------------------------------------------------------------------
local tex_cache, stats = {}, { uploads = 0, emits = 0, presents = 0, skipped = 0, refusals = 0, sprites = 0 }
function M.stats()
	local out = {}
	for k, v in pairs(stats) do out[k] = v end
	return out
end

-- A soft round sprite for stars: a bright core and a falloff, 32 px.
local function dot_pixels()
	local n, out = 32, {}
	local c = (n - 1) / 2
	for y = 0, n - 1 do
		for x = 0, n - 1 do
			local d = math.sqrt((x - c) ^ 2 + (y - c) ^ 2) / c
			local a = d >= 1 and 0 or (math.exp(-d * d * 5.5) * (1 - d) ^ 0.6)
			out[#out + 1] = string.char(255, 255, 255, floor(255 * min(1, a * 1.15) + 0.5))
		end
	end
	return table.concat(out), n, n
end

-- NanoSVG through core.ui.VectorIcon, for a file under ASSET_DIR or an inline string; nil
-- without it.
local function svg_pixels(src, w, h)
	local ok, VectorIcon = pcall(require, "core.ui.VectorIcon")
	if not (ok and VectorIcon.available and VectorIcon.rasterize) then return nil end
	if not src:find("<svg", 1, true) then
		if not M.ASSET_DIR then return nil end
		local sep = M.ASSET_DIR:find("\\", 1, true) and "\\" or "/"
		src = M.ASSET_DIR .. sep .. src
	end
	return VectorIcon.rasterize(src, w, h)
end
M._svg_pixels = svg_pixels -- specs replace it

local function texture(B, key, make)
	local c = tex_cache[key]
	if c ~= nil then return c or nil end
	local px, w, h = make()
	local id = px and B.texture and B.texture(px, w, h)
	tex_cache[key] = id or false
	if id then stats.uploads = stats.uploads + 1 end
	return id
end
--- Forget textures (a device reset, a new backend).
function M.reset()
	tex_cache = {}
	M._last_key, M._target = nil, nil
end

-- An svg layer's (or a video's poster's) texture for art `src`: its box `width` x `height`
-- (or `size`) px, rasterized at `raster` times that (above 1 for a layer scaled up, below
-- for soft glows that need no detail).
local function layer_texture(B, layer, src)
	local def = layer.def
	if not src then return nil end
	local bw = def.width or def.size or 64
	local bh = def.height or def.size or bw
	local rs = def.raster or 1
	return texture(B, src .. "|" .. bw .. "x" .. bh .. "@" .. rs, function()
		return M._svg_pixels(src, max(1, floor(bw * rs + 0.5)), max(1, floor(bh * rs + 0.5)))
	end), bw, bh
end

-- Every texture a scene can show, made when it first becomes active, so no element
-- uploads mid-animation (the crescent's first slide, the first switch to light).
local function warm(B, scene)
	if scene.warm == B then return end
	scene.warm = B
	for _, layer in ipairs(scene.layers) do
		if layer.kind == "stars" then texture(B, "dot", dot_pixels)
		elseif layer.arts then
			for _, src in ipairs(layer.arts) do layer_texture(B, layer, src) end
		end
	end
end

-- Drawing ------------------------------------------------------------------------------
local COVER = "\0cover"   -- s[COVER .. i]: a `whole` layer's visibility (M.cover)
local function pack(c, a)
	return Color.pack(c[1], c[2], c[3], (c[4] or 255) * (a or 1))
end

-- Draw `scene` with signals `s` on B, in a w x h window. Returns the sprite count.
local function emit(B, scene, s, w, h, ctx)
	local n = 0
	for i, layer in ipairs(scene.layers) do
		local opacity = layer.opacity(s)
		if layer.whole and type(opacity) == "number" then opacity = opacity * (s[COVER .. i] or 1) end
		if type(opacity) == "number" and opacity > 0.002 then
			local kind = layer.kind
			if kind == "fill" then
				local top, bottom = layer.top(s), layer.bottom(s)
				local a, b = pack(top, opacity), pack(bottom, opacity)
				if B.rect_gradient then B.rect_gradient(0, 0, w, h, a, a, b, b)
				else B.rect_filled(0, 0, w, h, a, 0, 0) end
				n = n + 1
			elseif kind == "stars" then
				local id = texture(B, "dot", dot_pixels)
				if id then
					local t, amount = s.time or 0, layer.amount
					local par = layer.parallax(s)
					local mx, my = (s.mouse_x or 0) * par, (s.mouse_y or 0) * par
					local tint = layer.tint(s)
					local dx, dy = layer.dx(s), layer.dy(s)
					local cap, left, top, bottom = 1, -1, -1, h + 1
					if layer.frame_cap then
						cap = min(1, layer.frame_cap / opacity)
						left, top, bottom = layer.frame_left(s), layer.def.frame.top or 0, h - (layer.def.frame.bottom or 0)
					end
					for _, st in ipairs(layer.stars) do
						local a = st.base * opacity
						if st.twinkles and amount > 0 then
							a = a * (1 - amount * (0.5 + 0.5 * sin(2 * pi * (t / st.period + st.phase))))
						end
						if a > 0.01 then
							local x = st.u * w + dx - mx * st.depth
							local y = st.v * h + dy - my * st.depth
							if x < left or y < top or y > bottom then a = a * cap end
							local r = st.r * 2.2   -- the sprite's falloff reaches past the core
							local col = st.color
							B.image(id, x - r, y - r, x + r, y + r, 0, 0, 1, 1,
								Color.pack(col[1] * tint[1] / 255, col[2] * tint[2] / 255, col[3] * tint[3] / 255, 255 * min(1, a)))
							n = n + 1
						end
					end
				end
			else
				-- svg (and a video's poster): one sprite, anchored at its centre
				local def = layer.def
				local id, bw, bh = layer_texture(B, layer, layer.art(s))
				if id then
					local scale = layer.scale(s)
					local par = layer.parallax(s)
					-- x, y: fractions of the window, or px with `unit = "px"` (negative: from the
					-- right or bottom edge)
					local lx, ly = layer.x(s), layer.y(s)
					if def.unit == "px" then
						lx = lx < 0 and w + lx or lx
						ly = ly < 0 and h + ly or ly
					else
						lx, ly = lx * w, ly * h
					end
					local cx = lx + layer.dx(s) - (s.mouse_x or 0) * par
					local cy = ly + layer.dy(s) - (s.mouse_y or 0) * par
					local hw, hh = bw * scale / 2, bh * scale / 2
					local rot = layer.rotation(s)
					local col = pack(layer.tint(s), opacity)
					if rot ~= 0 and B.image_quad then
						local ca, sa = cos(rot * pi / 180), sin(rot * pi / 180)
						local function at(px, py) return cx + px * ca - py * sa, cy + px * sa + py * ca end
						local x1, y1 = at(-hw, -hh)
						local x2, y2 = at(hw, -hh)
						local x3, y3 = at(hw, hh)
						local x4, y4 = at(-hw, hh)
						B.image_quad(id, x1, y1, x2, y2, x3, y3, x4, y4, col)
					else
						B.image(id, cx - hw, cy - hh, cx + hw, cy + hh, 0, 0, 1, 1, col)
					end
					n = n + 1
				end
				if kind == "video" then stats.video_poster = (stats.video_poster or 0) + 1 end
			end
		end
	end
	return n
end
M._emit = emit

-- State --------------------------------------------------------------------------------
local active             -- the compiled scene in use
local last_values = {}   -- the signals the last emission read
local last_emit = -1e9
local animated = false   -- may time and the pointer move it (motion on, GPU path)
local window = { w = 0, h = 0 }
local pending_resize = false   -- a resize stretched the last render; one more is due
local last_resize = -1e9       -- when the window last changed size
local seen_size                -- the window size the last frame had
local listed                   -- the target size the last full frame's lists sample at
M.RESIZE_HZ = 30        -- GPU path: redraws during a live resize at most this often
M.RESIZE_SETTLE = 0.15  -- static path (WARP, motion off): the last render stretches until
                        -- the size has held this long, then one redraw
local EASE_HZ = 60      -- a mode ease redraws at most this often
local target            -- { tw, th } of the scene target, while one holds the scene

local function motion()
	local Reactor = package.loaded["core.ui.ThemeReactor"]
	local manager = Reactor and Reactor.themeManager()
	local director = manager and manager._motion
	return director and director:enabled() or false, director
end

--- Is `p`'s scene live on this backend (it has a background)?
function M.of(p) return p and p.background and p.background.layers and scene_of(p.background) or nil end

--- Do palettes `a` and `b` show one scene (a switch between them eases it, not a fade)?
function M.shared(a, b)
	local x, y = a and a.background, b and b.background
	return x ~= nil and y ~= nil and (x == y or (x.id ~= nil and x.id == y.id))
end

-- Follow the palette: a new background starts fresh; the same one with another mode eases,
-- MODE_DELAY after the UI has switched.
local function follow(p, now)
	local bg = p.background
	local scene = scene_of(bg)
	local want = p.glassDark == false and 1 or 0
	-- one scene by M.shared's rule: the same table (with or without an id) or the same id
	if not active or not M.shared({ background = active.bg }, p) then
		mode.value, mode.from, mode.to, mode.at, mode.dur, mode.tail = want, want, want, now, 0, false
		last_values = {}
	elseif want ~= mode.to then
		local on, director = motion()
		local cur = signals.mode.read({ now = now })
		local scale = director and director._scale or 1
		-- off the GPU path (WARP, hardware acceleration off) the scene is static: the
		-- switch is one render, not a render per frame of the ease
		local eases = on and animated
		mode.from, mode.to = cur, want
		mode.at = now + (eases and M.MODE_DELAY * scale or 0)
		mode.dur = eases and M.MODE_EASE * scale or 0
		mode.tail = mode.dur > 0
	end
	active = scene
	M._deps = scene.deps
	return scene
end

local function now_of()
	local R = package.loaded["core.imgui.Runtime"]
	return R and R.now and R.now() or 0
end

--- How far the sky still is from the mode the UI shows: 0 at rest, 1 when it has not
-- started to move (a switch's first MODE_DELAY).
function M.lag(now)
	if not active or mode.dur <= 0 then return 0 end
	now = now or now_of()
	if now >= mode.at + mode.dur then return 0 end
	return math.abs(mode.to - signals.mode.read({ now = now }))
end

local function context(now, w, h)
	local R = package.loaded["core.imgui.Runtime"]
	local ctx = { now = now, w = w, h = h, static = not animated }
	if animated and R and R.pointer then
		local px, py, inside = R.pointer()
		if inside and px and px >= 0 then
			ctx.mx = max(-1, min(1, px / max(1, w) * 2 - 1))
			ctx.my = max(-1, min(1, py / max(1, h) * 2 - 1))
		end
	end
	return ctx
end

-- The signal values `scene` reads now, time quantized to its fps; changed = differs from
-- the last emission.
local function read(scene, ctx)
	local s, changed = {}, false
	for name in pairs(scene.deps) do
		local sig = signals[name]
		if sig then
			local v = sig.read(ctx)
			if name == "time" then v = floor(v * scene.fps) / scene.fps end
			s[name] = v
			if last_values[name] ~= v then changed = true end
		elseif name ~= "*" then
			s[name] = pushed[name] or 0
			if last_values[name] ~= s[name] then changed = true end
		end
	end
	for i, layer in ipairs(scene.layers) do
		local wh = layer.whole
		if wh then
			local v = wh.to
			if wh.dur > 0 and ctx.now < wh.at + wh.dur then
				local t = max(0, (ctx.now - wh.at) / wh.dur)
				v = wh.from + (wh.to - wh.from) * t * t * (3 - 2 * t)
			end
			s[COVER .. i] = v
			if last_values[COVER .. i] ~= v then changed = true end
		end
	end
	return s, changed
end

--- Drop the active scene and its idle scheduling, keeping pushed signals (the rail) for
-- when a scene shows again: the theme left it (Lunar -> Carbon).
function M.deactivate()
	active, target, M._deps, last_values, last_emit = nil, nil, nil, {}, -1e9
	pending_resize, listed, seen_size, M._target_size = false, nil, nil, nil
	mode.from, mode.to, mode.dur, mode.tail = 0, 0, 0, false
end

-- Is the active scene still the palette's (the theme may have changed since it drew)?
local function current()
	if not active then return false end
	local Reactor = package.loaded["core.ui.ThemeReactor"]
	local ok, p = pcall(function() return Reactor and Reactor.palette and Reactor.palette() end)
	if ok and type(p) == "table" and not M.shared(p, { background = active.bg }) then
		M.deactivate()
		return false
	end
	return true
end
M._current = current

--- When should the scene be drawn again (M.now seconds), or nil: never on its own.
function M.due()
	if not current() then return nil end
	local now = now_of()
	if mode.dur > 0 and now < mode.at + mode.dur then
		-- an ease: from its start, at most EASE_HZ times a second
		return max(mode.at, last_emit + 1 / EASE_HZ)
	end
	-- the ease is over: one full frame at or after its end, so the frame's tint and the
	-- veil's bounds land on the final sky (a scene-only present would keep the last ones)
	if mode.tail then return max(mode.at + mode.dur, last_emit + 1 / EASE_HZ) end
	-- a body fading in or out as the layout over it changed (M.cover), to its last value
	for _, layer in ipairs(active.layers) do
		local wh = layer.whole
		if wh and wh.dur > 0 and last_emit < wh.at + wh.dur then
			return max(wh.at, last_emit + 1 / EASE_HZ)
		end
	end
	if pending_resize then
		return animated and last_emit + 1 / M.RESIZE_HZ or last_resize + M.RESIZE_SETTLE
	end
	if animated and active.deps.time then return last_emit + 1 / active.fps end
	if active.deps.clock then
		local t = os.date("*t")
		return now + (60 - t.sec)
	end
	return nil
end

local function draw_target(B, scene, s, w, h)
	local tw, th = B.scene_begin(w, h)
	if not tw then return nil end
	local ok, n = pcall(emit, B, scene, s, w, h)
	B.scene_end(ok and n or 0)
	if not ok then
		local log = package.loaded["core.lib.log"]
		if log and log.warn then log.warn("scene: " .. tostring(n)) end
		return nil
	end
	stats.sprites = n
	return { tw = tw, th = th, w = w, h = h }
end

--- Paint the floor at (x, y, w, h) of the main window on `dc` with `p`'s scene; false
-- when `p` has none. `live`: the GPU path (time and the pointer may move it).
function M.floor(dc, x, y, w, h, p, live)
	local B = dc.B
	if not M.of(p) then if active then M.deactivate() end; return false end
	local now = now_of()
	animated = live and (motion()) or false
	local scene = follow(p, now)
	warm(B, scene)
	local W, H = dc.window_w or w, dc.window_h or h
	window.w, window.h = W, H
	-- a full frame at or after the ease's end: the tail is drawn
	if mode.tail and now >= mode.at + mode.dur then mode.tail = false end
	local ctx = context(now, W, H)
	local s, changed = read(scene, ctx)
	if scene.wholes and dc.coverBegin and (dc.surface_id or 0) == 0 then dc:coverBegin() end
	if B.scene_begin and (dc.surface_id or 0) == 0 then
		local size = W .. "x" .. H
		if seen_size ~= size then seen_size, last_resize = size, now end
		local resized = M._target_size ~= size
		-- a live resize stretches the last render over the window: on the GPU path it is
		-- drawn again at most RESIZE_HZ times a second, on the static path once the size
		-- has held for RESIZE_SETTLE; either way a last one follows when it settles (M.due)
		local hold
		if animated then hold = now - last_emit < 1 / M.RESIZE_HZ - 1e-6 else hold = now - last_resize < M.RESIZE_SETTLE - 1e-6 end
		if resized and target and B.scene_valid() and hold then
			pending_resize = true
			stats.stretched = (stats.stretched or 0) + 1
		elseif changed or not target or not B.scene_valid() or resized then
			pending_resize = false
			target = draw_target(B, scene, s, W, H)
			if target then
				last_values, last_emit = s, now
				M._target_size = size
				stats.emits = stats.emits + 1
			end
		else
			stats.skipped = stats.skipped + 1
			-- the size came back to the target's within the hold (A -> B -> A): nothing is
			-- stretched any more, so no redraw is owed
			if not resized then pending_resize = false end
		end
		if target then
			-- the target's rendered area (target.w x target.h) maps onto the window
			local sx, sy = target.w / (W * target.tw), target.h / (H * target.th)
			dc:_emit("image", B.SCENE_SHARP, x + dc.ox, y + dc.oy, x + dc.ox + w, y + dc.oy + h,
				(x + dc.ox) * sx, (y + dc.oy) * sy, (x + dc.ox + w) * sx, (y + dc.oy + h) * sy,
				dc:_color(0xFFFFFFFF))
			listed = target.w .. "x" .. target.h
			-- the next time-bound draw is the idle loop's (Runtime.step asks M.due), as a
			-- scene-only present: a wake here would make it a frame of the UI
			return true
		end
	end
	-- No scene target (an SDL host, the Null backend, a dialog window): the layers straight
	-- onto this list, static.
	local sctx = context(now, W, H); sctx.static = true
	local st = read(scene, sctx)
	dc:clip_push(x, y, w, h)
	local ox, oy = dc.ox, dc.oy
	local Bshift = setmetatable({}, { __index = B })
	if ox ~= 0 or oy ~= 0 then
		function Bshift.image(id, x1, y1, x2, y2, ...) return B.image(id, x1 + ox, y1 + oy, x2 + ox, y2 + oy, ...) end
		function Bshift.rect_gradient(x1, y1, x2, y2, ...) return B.rect_gradient(x1 + ox, y1 + oy, x2 + ox, y2 + oy, ...) end
	end
	emit(Bshift, scene, st, W, H)
	dc:clip_pop()
	return true
end

--- The scene target for chrome glass: sharp id, blur id, and px -> uv (ku, kv); nil when
-- the scene is not in a target.
function M.textures(B)
	if not (active and target and B.SCENE_SHARP) then return nil end
	local W, H = max(1, window.w), max(1, window.h)
	return B.SCENE_SHARP, B.SCENE_BLUR, target.w / (W * target.tw), target.h / (H * target.th)
end

--- From the runtime's idle loop, when M.due() has come: draw the scene again and present
-- it without a frame of the UI. Returns true when done (or nothing changed), false when a
-- full frame is needed instead: during a mode ease (the frame's tint and the chrome follow
-- the sky, see M.frameAlpha), when the size changed since the last full frame (its lists'
-- uvs are for the old size), when the theme left the scene.
function M.tick(B)
	if not current() or not target or not (B and B.scene_present) then return false end
	local now = now_of()
	if mode.dur > 0 and now < mode.at + mode.dur or mode.tail then return false end
	animated = animated and (motion()) or false
	local ctx = context(now, window.w, window.h)
	local s, changed = read(active, ctx)
	if not changed and not pending_resize then last_emit = now; stats.skipped = stats.skipped + 1; return true end
	if pending_resize or listed ~= window.w .. "x" .. window.h then return false end
	if not B.scene_valid() then return false end
	local t = draw_target(B, active, s, window.w, window.h)
	if not t then return false end
	target = t
	last_values, last_emit = s, now
	stats.emits = stats.emits + 1
	if B.scene_present() then
		stats.presents = stats.presents + 1
		return true
	end
	stats.refusals = stats.refusals + 1
	return false
end

-- Whole or hidden -------------------------------------------------------------------------
-- A layer with `whole = true` (the moon, the sun) is never shown in part. After each frame
-- of the UI the runtime passes the opaque fills it laid over the scene (core.imgui.Draw
-- records them from the floor on; a page sliding in counts where it will rest), and each
-- such layer's box (art and glow, plus parallax) is tested against them where the layer
-- will be (at the mode the sky is easing to). Wholly clear or wholly covered, it shows;
-- partly covered, it fades out over COVER_FADE, and back in when that changes.
M.COVER_FADE = 0.15  -- s
M.COVER_STEP = 8     -- px between the points tested across a box

-- The box (x0, y0, x1, y1) `layer` takes up with signals `s` in a W x H window.
local function box_of(layer, s, W, H)
	local def = layer.def
	local bw = def.width or def.size or 64
	local bh = def.height or def.size or bw
	local sc, par = layer.scale(s), math.abs(layer.parallax(s))
	local lx, ly = layer.x(s), layer.y(s)
	if def.unit == "px" then
		lx = lx < 0 and W + lx or lx
		ly = ly < 0 and H + ly or ly
	else
		lx, ly = lx * W, ly * H
	end
	local cx, cy = lx + layer.dx(s), ly + layer.dy(s)
	local hw, hh = bw * sc / 2 + par, bh * sc / 2 + par
	return cx - hw, cy - hh, cx + hw, cy + hh
end
M._box_of = box_of

--- How much of box (x0, y0, x1, y1) `rects` ({ x0, y0, x1, y1 }, ...) cover: "clear",
-- "covered" or "partial", tested at points COVER_STEP apart across it (edges included).
function M.coverage(x0, y0, x1, y1, rects)
	local hits = {}
	for _, r in ipairs(rects) do
		if r[1] <= x1 and r[3] >= x0 and r[2] <= y1 and r[4] >= y0 then hits[#hits + 1] = r end
	end
	if #hits == 0 then return "clear" end
	local nx = max(1, math.ceil((x1 - x0) / M.COVER_STEP))
	local ny = max(1, math.ceil((y1 - y0) / M.COVER_STEP))
	local inside, total = 0, 0
	for j = 0, ny do
		local y = y0 + (y1 - y0) * j / ny
		for i = 0, nx do
			local x = x0 + (x1 - x0) * i / nx
			total = total + 1
			for k = 1, #hits do
				local r = hits[k]
				if x >= r[1] and x <= r[3] and y >= r[2] and y <= r[4] then inside = inside + 1; break end
			end
		end
	end
	if inside == 0 then return "clear" end
	return inside == total and "covered" or "partial"
end

--- After a frame of the UI: `rects`, the opaque fills laid over the scene (screen px).
-- Starts the fades of the `whole` layers whose coverage changed; true when one did.
function M.cover(rects)
	if not (active and active.wholes and rects) then return false end
	local W, H = window.w, window.h
	if W <= 0 or H <= 0 then return false end
	local now = now_of()
	local s = setmetatable({ mode = mode.to, width = W, height = H }, { __index = last_values })
	local started = false
	for _, layer in ipairs(active.layers) do
		local wh = layer.whole
		if wh then
			local x0, y0, x1, y1 = box_of(layer, s, W, H)
			local state = M.coverage(x0, y0, x1, y1, rects)
			local want = state == "partial" and 0 or 1
			wh.state = state
			if not wh.seen then
				-- the first layout it meets: no fade from what was never shown
				wh.seen, wh.from, wh.to, wh.at, wh.dur = true, want, want, now, 0
				started = started or want == 0
			elseif want ~= wh.to then
				local cur = wh.to
				if wh.dur > 0 and now < wh.at + wh.dur then
					local t = max(0, (now - wh.at) / wh.dur)
					cur = wh.from + (wh.to - wh.from) * t * t * (3 - 2 * t)
				end
				local on, director = motion()
				local scale = director and director._scale or 1
				wh.from, wh.to, wh.at = cur, want, now
				wh.dur = (on and animated) and M.COVER_FADE * scale or 0
				started = true
			end
		end
	end
	if started then
		local R = package.loaded["core.imgui.Runtime"]
		if R and R.wakeAt then R.wakeAt(now) end
	end
	return started
end
--- A `whole` layer's last coverage ("clear", "covered", "partial") and visibility now.
function M.coverState(i)
	local layer = active and active.layers[i]
	local wh = layer and layer.whole
	if not wh then return nil end
	return wh.state, (read(active, { now = now_of(), w = window.w, h = window.h, static = true }))[COVER .. i]
end

--- Does a pointer move change the scene (a parallax layer, motion on)?
function M.wantsPointer() return active ~= nil and animated and active.deps.mouse_x == true end

-- Contrast ---------------------------------------------------------------------------------
-- Labels on the frame lie over the scene under the frame's tint. A layer may give `peak`
-- = { colour, alpha }, the brightest pixel of its art (a star field's is its brightest
-- colour at its `frame` cap, else its opacity), and `labels = false` when it never lies
-- under labels (kept clear of them, or faded out where they are).
local function lin(v) v = v / 255; return v <= 0.04045 and v / 12.92 or ((v + 0.055) / 1.055) ^ 2.4 end
local function luminance(c) return 0.2126 * lin(c[1]) + 0.7152 * lin(c[2]) + 0.0722 * lin(c[3]) end
M.luminance = luminance
local function over(under, c, a)
	return { under[1] + (c[1] - under[1]) * a, under[2] + (c[2] - under[2]) * a, under[3] + (c[3] - under[3]) * a }
end
M.over = over

--- The brightest and darkest pixel (sRGB 0..255) `bg`'s scene can put under the frame's
-- labels with signals `s` (`mode`; the rest read 0 unless given), from its layer table.
-- `bg.labels = { top, bottom, left, sizes }` names the strips where labels lie (px; `left`
-- may be bound, `sizes` the window sizes to check, default 1920x1080 and 1084x792). A glow
-- (`glow = { colour, alpha, mid }`: an ellipse filling its box, alpha falling linearly to
-- `alpha * 0.45` at `mid` and to 0 at its edge) counts at the nearest point of those strips
-- (less its parallax); a star field at its `frame` cap; another layer at its `peak` = {
-- colour, alpha }, unless `labels = false` (it never lies under labels). Glows are taken
-- not to overlap one another there, nor star fields: the brightest of each counts.
local function glow_alpha(g, d)
	local a, mid = g[2] or 1, g[3] or 0.45
	if d >= 1 then return 0 end
	if d <= mid then return a + (a * 0.45 - a) * (d / mid) end
	return a * 0.45 * (1 - (d - mid) / (1 - mid))
end
-- the nearest distance from (cx, cy) to rect (x, y, w, h), in units of the radii rx, ry
local function reach(cx, cy, rx, ry, x, y, w, h)
	local px, py = max(x, min(cx, x + w)), max(y, min(cy, y + h))
	return math.sqrt(((px - cx) / rx) ^ 2 + ((py - cy) / ry) ^ 2)
end
function M.extremes(bg, s)
	local scene = scene_of(bg)
	local lab = bg.labels or {}
	local left = compile(lab.left or 0, {})
	local sizes = lab.sizes or { { 1920, 1080 }, { 1084, 792 } }
	local bright, dark
	local glow_c, glow_a, star_c, star_a = nil, 0, nil, 0
	for _, layer in ipairs(scene.layers) do
		local def = layer.def
		local o = layer.opacity(s)
		if type(o) == "number" and o > 0.002 and def.labels ~= false then
			local t = layer.tint(s)
			local function tinted(c) return { c[1] * t[1] / 255, c[2] * t[2] / 255, c[3] * t[3] / 255 } end
			if layer.kind == "fill" then
				local a, b = layer.top(s), layer.bottom(s)
				local hi, lo = a, b
				if luminance(b) > luminance(a) then hi, lo = b, a end
				bright = over(bright or { 0, 0, 0 }, hi, o)
				dark = over(dark or { 0, 0, 0 }, lo, o)
			elseif layer.kind == "stars" then
				local c
				for _, col in ipairs(def.colors or { "#FFFFFF" }) do
					local v = rgba(col)
					if not c or luminance(v) > luminance(c) then c = v end
				end
				local a = def.frame and def.frame.opacity and min(o, def.frame.opacity) or o
				if a > star_a then star_c, star_a = tinted(c), a end
			elseif def.glow then
				local bw, bh = def.width or def.size or 64, def.height or def.size or def.width or 64
				local sc, par = layer.scale(s), layer.parallax(s)
				for _, size in ipairs(sizes) do
					local W, H = size[1], size[2]
					for _, rail in ipairs({ 0, 1 }) do
						local ss = setmetatable({ width = W, height = H, rail = rail }, { __index = s })
						local cx, cy = layer.x(ss), layer.y(ss)
						if def.unit ~= "px" then cx, cy = cx * W, cy * H end
						cx, cy = cx + layer.dx(ss), cy + layer.dy(ss)
						local rx, ry = bw * sc / 2, bh * sc / 2
						local l = left(ss)
						local d = math.min(reach(cx, cy, rx, ry, 0, 0, W, lab.top or 0),
							reach(cx, cy, rx, ry, 0, H - (lab.bottom or 0), W, lab.bottom or 0),
							reach(cx, cy, rx, ry, 0, 0, l, H))
						d = max(0, d - par / min(rx, ry))
						local a = glow_alpha(def.glow, d) * o
						if a > glow_a then glow_c, glow_a = tinted(rgba(def.glow[1])), a end
					end
				end
			elseif def.peak then
				local c, a = tinted(rgba(def.peak[1])), (def.peak[2] or 1) * o
				if bright and luminance(c) >= luminance(bright) then bright = over(bright, c, a) end
				if dark and luminance(c) < luminance(dark) then dark = over(dark, c, a) end
			end
		end
	end
	bright, dark = bright or { 0, 0, 0 }, dark or { 0, 0, 0 }
	for _, part in ipairs({ { glow_c, glow_a }, { star_c, star_a } }) do
		local c, a = part[1], part[2]
		if c and a > 0 then
			if luminance(c) >= luminance(bright) then bright = over(bright, c, a) end
			if luminance(c) < luminance(dark) then dark = over(dark, c, a) end
		end
	end
	return bright, dark
end

--- Where the scene may be brighter (or darker) than a glass body's bounds allow under its
-- tint: screen rects (x0, y0, x1, y1) of the layers whose brightest pixel (`peak`, a glow's
-- `glow`, else white), under `tint` (sRGB) at `alpha`, leaves luminance above `hi` or below
-- `lo`, as drawn now, over the sky's brightest / darkest; nil when the sky alone under the
-- tint is outside them. A star field is never listed: its opacity must keep it inside (a
-- spec checks Lunar's). The glass draws its clamped body only over these.
function M.hot(tint, alpha, hi, lo)
	local out = {}
	if not active or not target then return nil end
	local s = last_values
	local W, H = window.w, window.h
	-- the sky (fill layers) at its brightest and darkest: the body alone must already be
	-- inside the bounds over it, else nil (the caller bounds the whole body)
	local bright, dark
	for _, layer in ipairs(active.layers) do
		if layer.kind == "fill" then
			local o = layer.opacity(s)
			local a, b = layer.top(s), layer.bottom(s)
			local up, down = a, b
			if luminance(b) > luminance(a) then up, down = b, a end
			bright = over(bright or { 0, 0, 0 }, up, o)
			dark = over(dark or { 0, 0, 0 }, down, o)
		end
	end
	bright, dark = bright or { 0, 0, 0 }, dark or { 0, 0, 0 }
	if luminance(over(bright, tint, alpha)) > hi or luminance(over(dark, tint, alpha)) < lo then return nil end
	for _, layer in ipairs(active.layers) do
		local def = layer.def
		local kind = layer.kind
		if kind == "svg" or kind == "video" then
			local o = layer.opacity(s)
			if type(o) == "number" and o > 0.002 then
				local c, a = { 255, 255, 255 }, o
				if def.glow then c, a = rgba(def.glow[1]), (def.glow[2] or 1) * o
				elseif def.peak then c, a = rgba(def.peak[1]), (def.peak[2] or 1) * o end
				local t = layer.tint(s)
				c = { c[1] * t[1] / 255, c[2] * t[2] / 255, c[3] * t[3] / 255 }
				if luminance(over(over(bright, c, a), tint, alpha)) > hi
					or luminance(over(over(dark, c, a), tint, alpha)) < lo then
					local bw, bh = def.width or def.size or 64, def.height or def.size or def.width or 64
					local sc, par = layer.scale(s), layer.parallax(s)
					local lx, ly = layer.x(s), layer.y(s)
					if def.unit == "px" then
						lx = lx < 0 and W + lx or lx
						ly = ly < 0 and H + ly or ly
					else
						lx, ly = lx * W, ly * H
					end
					local cx, cy = lx + layer.dx(s), ly + layer.dy(s)
					-- any turn and the pointer's parallax; `hot` (0..1): the part of the box,
					-- round its centre, where the art is that bright (default all of it)
					local r = math.sqrt(bw * bw + bh * bh) * sc / 2 * (def.hot or 1) + math.abs(par) + 2
					out[#out + 1] = { cx - r, cy - r, cx + r, cy + r }
				end
			end
		end
	end
	return out
end

local function ratio(a, b)
	local x, y = luminance(a), luminance(b)
	if x < y then x, y = y, x end
	return (x + 0.05) / (y + 0.05)
end
M.ratio = ratio

-- per palette: the frame's alpha needed with the sky at mode 0, 1/STEPS, .. 1
local frame_needs = setmetatable({}, { __mode = "k" })
local STEPS = 20
M.FRAME_CONTRAST = 4.6

--- The frame's tint alpha now: `glassFrameAlpha` at rest; while a switch's sky has not yet
-- reached the mode the UI shows, as much more as keeps the palette's text and muted text
-- at FRAME_CONTRAST over the worst pixel the sky can show at its current mode.
function M.frameAlpha(p, now)
	local rest = p.glassFrameAlpha or 0
	if not (active and p.background) or M.lag(now) <= 0 then return rest end
	local need = frame_needs[p]
	if not need then
		need = {}
		local tint = rgba(p.glassFrameTint or p.bg) or { 0, 0, 0 }
		local texts = { rgba(p.text), rgba(p.textMuted) }
		for i = 0, STEPS do
			local bright, dark = M.extremes(p.background, { mode = i / STEPS })
			local a = rest
			for _, worst in ipairs({ bright, dark }) do
				for _, t in ipairs(texts) do
					while a < 1 and ratio(t, over(worst, tint, a)) < M.FRAME_CONTRAST do a = min(1, a + 0.01) end
				end
			end
			need[i] = a
		end
		frame_needs[p] = need
	end
	local m = signals.mode.read({ now = now or now_of() }) * STEPS
	local i = floor(m)
	return max(need[max(0, min(STEPS, i))], need[max(0, min(STEPS, i + 1))])
end

--- Forget the active scene (theme without one, tests).
function M.clear()
	M.deactivate()
	t0 = nil
	for k in pairs(pushed) do pushed[k] = nil end
end

return M
