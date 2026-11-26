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
M.MODE_EASE = 0.9   -- s: the sky's dark/light change (scaled like other motion)
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

local mode = { value = nil, from = 0, to = 0, at = 0, dur = 0 }
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
	local t = (ctx.now - mode.at) / mode.dur
	t = t * t * (3 - 2 * t)
	return mode.from + (mode.to - mode.from) * t
end })
M.signal("mouse_x", { read = function(ctx) return ctx.static and 0 or ctx.mx or 0 end })
M.signal("mouse_y", { read = function(ctx) return ctx.static and 0 or ctx.my or 0 end })
M.signal("width", { read = function(ctx) return ctx.w end })
M.signal("height", { read = function(ctx) return ctx.h end })
M.signal("rail", { read = function() return pushed.rail or 0 end })
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

local function compile_layer(def)
	local layer = { def = def, kind = def.kind or (def.svg and "svg") or (def.file and "svg") or "fill", deps = {} }
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
		if layer.amount > 0 and share > 0 then layer.deps.time = true end
	end
	if layer.kind == "video" then layer.deps.time = true end
	-- a parallax offset reads the pointer
	if def.parallax and def.parallax ~= 0 then layer.deps.mouse_x, layer.deps.mouse_y = true, true end
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

-- An svg layer's (or a video's poster's) texture: its box `width` x `height` (or `size`)
-- px, rasterized at `raster` times that (above 1 for a layer scaled up, below for soft
-- glows that need no detail).
local function layer_texture(B, layer)
	local def = layer.def
	local src = def.svg or def.file or (def.poster and (def.poster.svg or def.poster.file))
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
		elseif layer.kind ~= "fill" then layer_texture(B, layer) end
	end
end

-- Drawing ------------------------------------------------------------------------------
local function pack(c, a)
	return Color.pack(c[1], c[2], c[3], (c[4] or 255) * (a or 1))
end

-- Draw `scene` with signals `s` on B, in a w x h window. Returns the sprite count.
local function emit(B, scene, s, w, h, ctx)
	local n = 0
	for _, layer in ipairs(scene.layers) do
		local opacity = layer.opacity(s)
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
					for _, st in ipairs(layer.stars) do
						local a = st.base * opacity
						if st.twinkles and amount > 0 then
							a = a * (1 - amount * (0.5 + 0.5 * sin(2 * pi * (t / st.period + st.phase))))
						end
						if a > 0.01 then
							local x = st.u * w + dx - mx * st.depth
							local y = st.v * h + dy - my * st.depth
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
				local id, bw, bh = layer_texture(B, layer)
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
M.RESIZE_HZ = 30
local target             -- { tw, th } of the scene target, while one holds the scene

local function motion()
	local Reactor = package.loaded["core.ui.ThemeReactor"]
	local manager = Reactor and Reactor.themeManager()
	local director = manager and manager._motion
	return director and director:enabled() or false, director
end

--- Is `p`'s scene live on this backend (it has a background)?
function M.of(p) return p and p.background and p.background.layers and scene_of(p.background) or nil end

-- Follow the palette: a new background starts fresh; the same one with another mode eases.
local function follow(p, now)
	local bg = p.background
	local scene = scene_of(bg)
	local want = p.glassDark == false and 1 or 0
	if not active or active.bg.id == nil or active.bg.id ~= bg.id then
		mode.value, mode.from, mode.to, mode.at, mode.dur = want, want, want, now, 0
		last_values = {}
	elseif want ~= mode.to then
		local on, director = motion()
		local cur = signals.mode.read({ now = now })
		mode.from, mode.to, mode.at = cur, want, now
		mode.dur = on and M.MODE_EASE * (director and director._scale or 1) or 0
	end
	active = scene
	M._deps = scene.deps
	return scene
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
	return s, changed
end

--- When should the scene be drawn again (M.now seconds), or nil: never on its own.
function M.due()
	if not active then return nil end
	local R = package.loaded["core.imgui.Runtime"]
	local now = R and R.now and R.now() or 0
	if mode.dur > 0 and now < mode.at + mode.dur then return now end
	if pending_resize then return last_emit + 1 / M.RESIZE_HZ end
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
	if not M.of(p) then active = nil; M._deps = nil; return false end
	local R = package.loaded["core.imgui.Runtime"]
	local now = R and R.now and R.now() or 0
	local scene = follow(p, now)
	warm(B, scene)
	animated = live and (motion()) or false
	local W, H = dc.window_w or w, dc.window_h or h
	window.w, window.h = W, H
	local ctx = context(now, W, H)
	local s, changed = read(scene, ctx)
	if B.scene_begin and (dc.surface_id or 0) == 0 then
		local resized = M._target_size ~= W .. "x" .. H
		-- a live resize redraws the scene at most RESIZE_HZ times a second; between, the last
		-- render stretches to the window and a last one follows when it settles (M.due)
		if resized and target and B.scene_valid() and now - last_emit < 1 / M.RESIZE_HZ then
			pending_resize = true
			stats.stretched = (stats.stretched or 0) + 1
		elseif changed or not target or not B.scene_valid() or resized then
			pending_resize = false
			target = draw_target(B, scene, s, W, H)
			if target then
				last_values, last_emit = s, now
				M._target_size = W .. "x" .. H
				stats.emits = stats.emits + 1
			end
		else
			stats.skipped = stats.skipped + 1
		end
		if target then
			-- the target's rendered area (target.w x target.h) maps onto the window
			local sx, sy = target.w / (W * target.tw), target.h / (H * target.th)
			dc:_emit("image", B.SCENE_SHARP, x + dc.ox, y + dc.oy, x + dc.ox + w, y + dc.oy + h,
				(x + dc.ox) * sx, (y + dc.oy) * sy, (x + dc.ox + w) * sx, (y + dc.oy + h) * sy,
				dc:_color(0xFFFFFFFF))
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
-- full frame is needed instead.
function M.tick(B)
	if not active or not target or not (B and B.scene_present) then return false end
	local R = package.loaded["core.imgui.Runtime"]
	local now = R and R.now and R.now() or 0
	animated = animated and (motion()) or false
	local ctx = context(now, window.w, window.h)
	local s, changed = read(active, ctx)
	if not changed and not pending_resize then last_emit = now; stats.skipped = stats.skipped + 1; return true end
	pending_resize = false
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

--- Does a pointer move change the scene (a parallax layer, motion on)?
function M.wantsPointer() return active ~= nil and animated and active.deps.mouse_x == true end

--- Forget the active scene (theme without one, tests).
function M.clear()
	active, target, M._deps, last_values, last_emit, t0 = nil, nil, nil, {}, -1e9, nil
	pending_resize = false
	mode.from, mode.to, mode.dur = 0, 0, 0
	for k in pairs(pushed) do pushed[k] = nil end
end

return M
