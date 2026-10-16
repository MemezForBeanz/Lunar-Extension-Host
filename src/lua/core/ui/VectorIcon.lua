--- Runtime SVG vector icon library backed by NanoSVG, replacing the offline PNG pipeline.
-- Each SVG is parsed once and cached for the process's lifetime; every (size, color,
-- rotation) combination is rasterized on demand and cached separately.  No baked
-- frames, no fixed size, no offline tooling: any size/color/angle is available at
-- runtime and repeats are free.
--
-- `VectorIcon.available` is `false` when LuaJIT FFI, the `svgicon` C bridge, or the
-- NanoSVG struct layout doesn't match what the host was compiled with; callers must
-- check this flag before use and provide their own fallback.
--
-- **One-shot usage** (e.g. a list's per-row `IMAGEid`):
--
--     local VectorIcon = require("core.ui.VectorIcon")
--     local handle = VectorIcon.imageHandle(iup, { path = P, size = 20, color = "#24a148" })
--     iup.SetAttributeId(list, "IMAGE", row, handle)
--
-- **Stateful widget usage** (bound to a label):
--
--     local icon = VectorIcon.new(iup, { path = P, size = 24, color = "#0f62fe" })
--     hbox:append(icon:widget())
--     icon:setColor("#da1e28")
--     icon:setRotation(45)
--     icon:spin(12)            -- begin continuous rotation at 12 fps
--     icon:stopSpin("#24a148") -- stop and settle on a color
--
-- @module core.ui.VectorIcon
local VectorIcon = {}
VectorIcon.__index = VectorIcon
VectorIcon.available = false

local ok_ffi, ffi = pcall(require, "ffi")
local ok_svgicon, svgicon = pcall(require, "svgicon")
if not (ok_ffi and ffi and ok_svgicon and svgicon) then
	return VectorIcon
end

-- core.ui.ThemeReactor owns ONE shared ThemeManager subscription + live-instance
-- registry for theme-reactive widgets (see its header comment); reusing it here means
-- icons recolor on theme switch through that same single hook instead of each widget
-- family wiring up its own ThemeManager plumbing.
local ok_kit, ThemeReactor = pcall(require, "core.ui.ThemeReactor")
if not ok_kit then
	ThemeReactor = nil
end

-- cdef is per-Lua-state and errors if redeclared; require() caches this module so
-- it normally runs once, but pcall keeps a stray re-require harmless.
pcall(ffi.cdef, [[
	typedef struct NSVGgradientStop {
		unsigned int color;
		float offset;
	} NSVGgradientStop;

	typedef struct NSVGgradient {
		float xform[6];
		char spread;
		float fx, fy;
		int nstops;
		NSVGgradientStop stops[1];
	} NSVGgradient;

	typedef struct NSVGpaint {
		signed char type;
		union {
			unsigned int color;
			NSVGgradient* gradient;
		};
	} NSVGpaint;

	typedef struct NSVGpath {
		float* pts;
		int npts;
		char closed;
		float bounds[4];
		struct NSVGpath* next;
	} NSVGpath;

	typedef struct NSVGshape {
		char id[64];
		NSVGpaint fill;
		NSVGpaint stroke;
		float opacity;
		float strokeWidth;
		float strokeDashOffset;
		float strokeDashArray[8];
		char strokeDashCount;
		char strokeLineJoin;
		char strokeLineCap;
		float miterLimit;
		char fillRule;
		unsigned char paintOrder;
		unsigned char flags;
		float bounds[4];
		char fillGradient[64];
		char strokeGradient[64];
		float xform[6];
		NSVGpath* paths;
		struct NSVGshape* next;
	} NSVGshape;

	typedef struct NSVGimage {
		float width;
		float height;
		NSVGshape* shapes;
	} NSVGimage;

	NSVGimage* nsvgParseFromFile(const char* filename, const char* units, float dpi);
	void nsvgDelete(NSVGimage* image);

	typedef struct NSVGrasterizer NSVGrasterizer;
	NSVGrasterizer* nsvgCreateRasterizer(void);
	void nsvgRasterize(NSVGrasterizer* r,
	                    NSVGimage* image, float tx, float ty, float scale,
	                    unsigned char* dst, int w, int h, int stride);
	void nsvgDeleteRasterizer(NSVGrasterizer* r);
]])

local C = ffi.C

-- Validate this module's hand-copied struct cdefs against the actual C sizeof()
-- from the same NanoSVG headers the host exe was compiled against (svgicon.sizeofs,
-- see svgicon_wrap.c). A mismatch means the vendored NanoSVG version drifted from
-- this file's cdef -- silently trusting it would corrupt memory the moment we walk
-- shape/path pointers, so we refuse to enable the module instead.
local function layout_matches()
	local ok_sizes, sizes = pcall(svgicon.sizeofs)
	if not ok_sizes or not sizes then
		return false
	end
	for _, name in ipairs({ "NSVGimage", "NSVGshape", "NSVGpath", "NSVGpaint", "NSVGgradient", "NSVGgradientStop" }) do
		local ok_sz, sz = pcall(ffi.sizeof, name)
		if not ok_sz or sz ~= sizes[name] then
			return false
		end
	end
	return true
end

if not layout_matches() then
	return VectorIcon
end

-- NanoSVG paint type enum (nanosvg.h: NSVGpaintType). Only COLOR paints are ever
-- produced by this library (see recolor() below) -- Carbon status icons are flat,
-- single-color glyphs -- but shapes may start out NONE (invisible helper rects,
-- e.g. Carbon's "Transparent Rectangle" convention) and must stay that way.
local NSVG_PAINT_NONE = 0
local NSVG_PAINT_COLOR = 1

local DEFAULT_COLOR = "#525252" -- Carbon Gray 70; used only if no color is given
local DEFAULT_SIZE = 20

-- Rotation happens about the icon's own center, and rotation preserves every
-- point's distance from that center -- so the ONLY thing that can clip is content
-- that already lies outside the canvas's inscribed circle (radius size/2). Rather
-- than shrink EVERY rotated glyph by the crude worst-case 1/sqrt(2) (which made
-- spinning icons visibly ~29% smaller than their static siblings), we measure each
-- glyph's actual content radius (farthest visible point from center, ignoring the
-- invisible full-canvas "Transparent Rectangle" helper shapes) and only shrink the
-- draw scale if that content would spill past the inscribed circle when rotated.
-- Carbon status glyphs (spinner ring, rotate arrows, etc.) keep their art within
-- that circle, so they now render at exactly the same size rotated or not.
local _contentRadius = {} -- image address -> farthest visible-content radius (px)

local function content_radius(image)
	local key = tonumber(ffi.cast("intptr_t", image))
	local cached = _contentRadius[key]
	if cached ~= nil then
		return cached
	end
	local cx, cy = image.width / 2, image.height / 2
	local maxR2 = 0
	local shape = image.shapes
	while shape ~= nil do
		-- Skip fully-invisible helper shapes (Carbon's transparent bounding rect
		-- spans the whole canvas and would otherwise dominate the radius).
		if shape.fill.type ~= NSVG_PAINT_NONE or shape.stroke.type ~= NSVG_PAINT_NONE then
			-- Measure the farthest ACTUAL path point from center (not the shape's
			-- axis-aligned bbox corner, which over-estimates round glyphs by up to
			-- sqrt(2) and would shrink them needlessly). Bezier control points bound
			-- the curve, so this is a safe (never-clipping) upper bound.
			local path = shape.paths
			while path ~= nil do
				local pts = path.pts
				local n = path.npts
				for i = 0, n - 1 do
					local dx = pts[i * 2] - cx
					local dy = pts[i * 2 + 1] - cy
					local d2 = dx * dx + dy * dy
					if d2 > maxR2 then
						maxR2 = d2
					end
				end
				path = path.next
			end
		end
		shape = shape.next
	end
	local maxR = math.sqrt(maxR2)
	_contentRadius[key] = maxR
	return maxR
end

-- ---------------------------------------------------------------------------
-- Theme-aware semantic colors
-- ---------------------------------------------------------------------------
--
-- Fallback hex values match the original tools/render_icons.py palette (Carbon
-- Gray-10/Classic theme's own support colors), so anything that resolves a role
-- before a theme has ever been applied looks identical to the old baked PNGs.
local ROLE_FALLBACK = {
	success = "#24a148",
	warning = "#f1c21b",
	error   = "#da1e28",
	info    = "#0f62fe",
	neutral = "#525252",
	accent  = "#0f62fe",
}

local ROLE_PALETTE_KEY = {
	success = "success",
	warning = "warning",
	error   = "error",
	info    = "info",
	neutral = "textMuted",
	accent  = "accent",
}

-- Theme palettes store colors as IUP's native "R G B" decimal-triplet string
-- (see carbon_rules.lua's rgb() helper), not "#RRGGBB". Converts one to the
-- other; returns nil if `s` isn't a well-formed "R G B" triplet.
local function rgb_string_to_hex(s)
	if type(s) ~= "string" then
		return nil
	end
	local r, g, b = s:match("^%s*(%d+)%s+(%d+)%s+(%d+)%s*$")
	if not r then
		return nil
	end
	return string.format("#%02x%02x%02x", tonumber(r), tonumber(g), tonumber(b))
end

--- Resolve a semantic color role to a `"#RRGGBB"` hex color from the active theme palette.
-- Falls back to Classic-theme-equivalent colors when no theme has been applied yet or
-- `ThemeReactor` is unavailable.
--
-- Supported roles: `"success"`, `"warning"`, `"error"`, `"info"`, `"neutral"`, `"accent"`.
-- @tparam string role Semantic role name.
-- @treturn string `"#RRGGBB"` hex color string.
function VectorIcon.roleColor(role)
	local fallback = ROLE_FALLBACK[role] or DEFAULT_COLOR
	if not ThemeReactor then
		return fallback
	end
	local ok, pal = pcall(ThemeReactor.palette)
	if not ok or not pal then
		return fallback
	end
	local key = ROLE_PALETTE_KEY[role]
	local raw = key and pal[key]
	return (raw and rgb_string_to_hex(raw)) or fallback
end

--- Wire the single shared `ThemeManager` `onApply` hook via `ThemeReactor`.
-- Idempotent; safe to call from multiple modules or multiple times with the same manager.
-- All `VectorIcon` instances registered with `ThemeReactor` will recolor on each theme switch.
-- @tparam table tm `ThemeManager` instance.
function VectorIcon.bindThemeManager(tm)
	if ThemeReactor then
		ThemeReactor.bindThemeManager(tm)
	end
end

-- ---------------------------------------------------------------------------
-- Parsing: each SVG is parsed once and kept for the process's lifetime. The
-- fixed Carbon icon set is small (a couple dozen files at most), so there is no
-- eviction policy -- this mirrors StatusIcon's old PNG cache, which never freed
-- anything either. NSVGimage* is intentionally never nsvgDelete'd for the same
-- reason: it must stay valid for every future render of that path.
-- ---------------------------------------------------------------------------
local _parseCache = {} -- path -> NSVGimage* cdata, or `false` for a known-bad path

local function parse_svg(path)
	local cached = _parseCache[path]
	if cached ~= nil then
		return cached or nil
	end
	local ok, image = pcall(C.nsvgParseFromFile, path, "px", 96)
	if not ok or image == nil then
		_parseCache[path] = false
		return nil
	end
	_parseCache[path] = image
	return image
end

-- ---------------------------------------------------------------------------
-- Color mutation
-- ---------------------------------------------------------------------------

-- "#RRGGBB" (or "RRGGBB") -> NanoSVG's packed color uint (0xAABBGGRR: R is the
-- lowest byte, matching nanosvg.h's NSVG_RGB(r,g,b) = r | g<<8 | b<<16, plus a
-- full-opacity alpha byte -- verified against the vendored nanosvgrast.h's pixel
-- compositing code, which reads channels in that exact order).
local function pack_color(hex)
	hex = tostring(hex or DEFAULT_COLOR):gsub("^#", "")
	local r = tonumber(hex:sub(1, 2), 16) or 0
	local g = tonumber(hex:sub(3, 4), 16) or 0
	local b = tonumber(hex:sub(5, 6), 16) or 0
	return r + g * 256 + b * 65536 + 255 * 16777216
end

-- Force every solid-color paint (fill and/or stroke) in the image to `colorU32`.
-- Paints that are NSVG_PAINT_NONE (e.g. Carbon's invisible "Transparent
-- Rectangle" helper shapes) are left untouched -- recoloring them would make an
-- invisible shape suddenly opaque. Mutates the shared cached NSVGimage directly;
-- safe because every render always re-applies its own color before rasterizing
-- (see render_to_buffer), so there is no cross-render state to preserve.
local function recolor(image, colorU32)
	local shape = image.shapes
	while shape ~= nil do
		if shape.fill.type == NSVG_PAINT_COLOR then
			shape.fill.color = colorU32
		end
		if shape.stroke.type == NSVG_PAINT_COLOR then
			shape.stroke.color = colorU32
		end
		shape.opacity = 1.0
		shape = shape.next
	end
end

-- ---------------------------------------------------------------------------
-- Rotation mutation
-- ---------------------------------------------------------------------------

-- Temporarily replaces every path's point buffer with a rotated copy (about the
-- image's own center) for the duration of the caller-supplied render, then
-- restores the originals -- so the shared pristine image is left exactly as it
-- was regardless of how many different angles get rendered over time. Returns
-- nothing; `body` is called synchronously and its result/error propagates.
local function with_rotation(image, angleDeg, body)
	if not angleDeg or math.abs(angleDeg) < 0.001 then
		body()
		return
	end

	local rad = math.rad(angleDeg)
	local cosA, sinA = math.cos(rad), math.sin(rad)
	local cx, cy = image.width / 2, image.height / 2

	-- Keep the freshly allocated rotated buffers reachable for the duration of
	-- the render (they're referenced from the C structs via raw `float*`,
	-- which the Lua GC cannot see) and remember each path's original pointer
	-- so it can be restored afterwards no matter how `body()` exits.
	local saved = {}
	local shape = image.shapes
	while shape ~= nil do
		local path = shape.paths
		while path ~= nil do
			local n = path.npts
			local rotated = ffi.new("float[?]", n * 2)
			local pts = path.pts
			for i = 0, n - 1 do
				local x, y = pts[i * 2] - cx, pts[i * 2 + 1] - cy
				rotated[i * 2] = cx + x * cosA - y * sinA
				rotated[i * 2 + 1] = cy + x * sinA + y * cosA
			end
			saved[#saved + 1] = { path = path, orig = pts, buf = rotated }
			path.pts = rotated
			path = path.next
		end
		shape = shape.next
	end

	local ok, err = pcall(body)
	for _, s in ipairs(saved) do
		s.path.pts = s.orig
	end
	if not ok then
		error(err, 0)
	end
end

-- ---------------------------------------------------------------------------
-- Rasterization
-- ---------------------------------------------------------------------------

-- One rasterizer context is created lazily and reused for the process's
-- lifetime (nanosvgrast.h explicitly documents it as reusable across images;
-- recreating it per render would repeatedly malloc/free its internal edge pool
-- for no benefit).
local _rasterizer

local function rasterizer()
	if not _rasterizer then
		_rasterizer = C.nsvgCreateRasterizer()
	end
	return _rasterizer
end

-- Renders `image` into a freshly allocated size x size RGBA buffer (uniformly
-- scaled + centered to fit, aspect preserved) at the given rotation/zoom/offset,
-- and returns (buf, size) -- or (nil, reason) on failure. `image` is expected to
-- already carry the desired paint colors (see recolor, applied by the caller
-- first). `zoom` (default 1.0) scales the icon within its canvas without
-- changing the canvas size; `offsetX`/`offsetY` (pixels, default 0) nudge the
-- centered position -- both are optical-alignment escape hatches for callers
-- that need pixel-perfect placement next to text/other widgets.
local function render_to_buffer(image, size, angleDeg, zoom, offsetX, offsetY)
	if image.width <= 0 or image.height <= 0 then
		return nil, "degenerate image bounds"
	end

	-- Fit-to-canvas scale (aspect preserved). Rotation only shrinks this if the
	-- glyph's real content would spill outside the inscribed circle once turned;
	-- content that already fits the circle renders at the SAME size at any angle.
	local scale = math.min(size / image.width, size / image.height)
	if angleDeg and math.abs(angleDeg) >= 0.001 then
		local r = content_radius(image)
		if r and r > 0 then
			local maxScale = (size / 2) / r
			if maxScale < scale then
				scale = maxScale
			end
		end
	end
	scale = scale * (zoom or 1.0)
	local drawnW, drawnH = image.width * scale, image.height * scale
	local tx = (size - drawnW) / 2 + (offsetX or 0)
	local ty = (size - drawnH) / 2 + (offsetY or 0)

	-- ffi.new zero-initializes the buffer, which matters here: nsvgRasterize
	-- alpha-blends shapes ON TOP of whatever the destination already holds, so
	-- it must start out fully transparent.
	local buf = ffi.new("uint8_t[?]", size * size * 4)

	local ok, err
	with_rotation(image, angleDeg, function()
		ok, err = pcall(C.nsvgRasterize, rasterizer(), image, tx, ty, scale, buf, size, size, size * 4)
	end)
	if not ok then
		return nil, tostring(err)
	end
	return buf, size
end

-- key -> IUP handle NAME (string), or `false` for a request that is known to fail.
-- Every distinct (path,size,color,rotation,zoom,offset) combination rasterizes
-- at most once.
local _imageCache = {}
local _handleSeq = 0

local function cache_key(path, size, colorHex, angleDeg, zoom, offsetX, offsetY)
	-- Rotation is quantized to whole degrees: it is only ever driven by the
	-- spinner's discrete animation steps in practice, and quantizing keeps the
	-- cache from growing unbounded under floating-point jitter.
	return string.format(
		"%s|%d|%s|%d|%.3f|%.1f|%.1f",
		path, size, colorHex or "", math.floor((angleDeg or 0) + 0.5),
		zoom or 1.0, offsetX or 0, offsetY or 0
	)
end

--- Render (or retrieve from cache) an SVG icon and return its IUP image handle name.
-- The handle is suitable for any IUP attribute that accepts an image handle name
-- (e.g. a widget's `IMAGE`, or a list's per-row `IMAGEid`).
-- Returns `nil, reason` on failure; never raises.
--
-- **opts fields:**
--
-- * `path` `string` *(required)* — absolute path to the source `.svg` file.
-- * `size` `number` (default `20`) — square render size in pixels.
-- * `color` `string` (default `"#525252"`) — `"#RRGGBB"` fill/stroke override.
-- * `rotation` `number` (default `0`) — clockwise rotation in degrees.
-- * `scale` `number` (default `1.0`) — zoom factor within the canvas.
-- * `offsetX`, `offsetY` `number` (default `0`) — pixel nudge from the centered position.
--
-- @tparam userdata iup The IUP library reference.
-- @tparam table opts Render options (see above).
-- @treturn string|nil IUP image handle name on success, or `nil` on failure.
-- @treturn string|nil Error reason string on failure.
function VectorIcon.imageHandle(iup, opts)
	opts = opts or {}
	if not opts.path then
		return nil, "opts.path is required"
	end
	local size = opts.size or DEFAULT_SIZE
	local color = opts.color or DEFAULT_COLOR
	local key = cache_key(opts.path, size, color, opts.rotation, opts.scale, opts.offsetX, opts.offsetY)

	local cached = _imageCache[key]
	if cached ~= nil then
		return cached or nil
	end

	local image = parse_svg(opts.path)
	if not image then
		_imageCache[key] = false
		return nil, "failed to parse " .. opts.path
	end

	recolor(image, pack_color(color))
	local buf, size_or_err = render_to_buffer(image, size, opts.rotation, opts.scale, opts.offsetX, opts.offsetY)
	if not buf then
		_imageCache[key] = false
		return nil, size_or_err
	end

	local addr = tonumber(ffi.cast("intptr_t", buf))
	local img, reason = svgicon.to_image(addr, size_or_err, size_or_err)
	if not img then
		_imageCache[key] = false
		return nil, reason
	end

	_handleSeq = _handleSeq + 1
	local handleName = "VectorIcon_" .. _handleSeq
	iup.SetHandle(handleName, img)
	_imageCache[key] = handleName
	return handleName
end

local _logoCache = {}  -- "path|height" -> IUP handle name, or `false` on failure

--- Render a multi-colour SVG (an org logo) at a fixed height, keeping its own
-- colours and aspect ratio, and return its IUP image handle name.
-- Unlike `imageHandle` this never recolours, so it parses its own copy of the
-- file rather than sharing the icon cache (whose images get recoloured).
-- @tparam userdata iup The IUP library reference.
-- @tparam string path Absolute path to the `.svg` file.
-- @tparam[opt=20] number height Height in pixels; width follows the aspect ratio.
-- @treturn string|nil IUP image handle name, or `nil` on failure.
-- @treturn string|nil Error reason on failure.
function VectorIcon.logoHandle(iup, path, height)
	height = math.max(1, math.floor(tonumber(height) or DEFAULT_SIZE))
	local key = tostring(path) .. "|" .. height
	local cached = _logoCache[key]
	if cached ~= nil then return cached or nil end

	local ok, image = pcall(C.nsvgParseFromFile, path, "px", 96)
	if not ok or image == nil or image.width <= 0 or image.height <= 0 then
		_logoCache[key] = false
		return nil, "failed to parse " .. tostring(path)
	end
	local scale = height / image.height
	local width = math.max(1, math.ceil(image.width * scale))
	local buf = ffi.new("uint8_t[?]", width * height * 4)  -- zeroed: transparent
	local ok_r, err = pcall(C.nsvgRasterize, rasterizer(), image, 0, 0, scale, buf, width, height, width * 4)
	C.nsvgDelete(image)
	if not ok_r then
		_logoCache[key] = false
		return nil, tostring(err)
	end

	local img, reason = svgicon.to_image(tonumber(ffi.cast("intptr_t", buf)), width, height)
	if not img then
		_logoCache[key] = false
		return nil, reason
	end
	_handleSeq = _handleSeq + 1
	local handleName = "VectorLogo_" .. _handleSeq
	iup.SetHandle(handleName, img)
	_logoCache[key] = handleName
	return handleName
end

-- ---------------------------------------------------------------------------
-- Stateful widget wrapper
-- ---------------------------------------------------------------------------
--
-- Binds a VectorIcon to a single iup.label, re-rendering (via the cache above,
-- so repeats are free) whenever its state changes. This is the counterpart to
-- the old StatusIcon widget -- StatusIcon.lua now shims over this directly.

--- Create a new stateful VectorIcon bound to an `iup.label` widget.
-- Accepts all opts from `imageHandle`, plus:
--
-- * `role` `string` — semantic color role (`"success"`, `"warning"`, etc.); resolved
--   from the active theme instead of a fixed hex color.  Ignored if `color` is also given.
--   Role-bound icons recolor automatically on every theme switch.
-- * `tip` `string` *(optional)* — initial tooltip text.
--
-- @tparam userdata iup The IUP library reference.
-- @tparam[opt] table opts Construction options (see above and `imageHandle`).
-- @treturn VectorIcon New stateful icon instance.
function VectorIcon.new(iup, opts)
	opts = opts or {}
	local self = setmetatable({}, VectorIcon)
	self.iup = iup
	self.path = opts.path
	self.size = opts.size or DEFAULT_SIZE
	self.role = (not opts.color) and opts.role or nil
	self.color = opts.color or (self.role and VectorIcon.roleColor(self.role)) or DEFAULT_COLOR
	self.rotation = opts.rotation or 0
	self.scale = opts.scale or 1.0
	self.offsetX = opts.offsetX or 0
	self.offsetY = opts.offsetY or 0
	self._spinning = false
	self.label = iup.label({
		title = "",
		TIP = opts.tip or "",
		ALIGNMENT = "ACENTER:ACENTER",
		RASTERSIZE = self.size .. "x" .. self.size,
	})
	if self.path then
		self:refresh()
	end
	if ThemeReactor then
		ThemeReactor.register(self)
	end
	return self
end

--- Internal: called once per theme switch by `ThemeReactor` for role-bound icons.
-- Role-bound icons recolor to the new theme's palette; fixed-color icons are unaffected.
-- @local
function VectorIcon:_onThemeApply()
	if self.role then
		self.color = VectorIcon.roleColor(self.role)
		self:refresh()
	end
end

--- Return the IUP label widget to add to a layout.
-- @treturn userdata IUP label handle.
function VectorIcon:widget()
	return self.label
end

--- Re-render from the current state and apply the image to the bound label.
-- The render cache makes repeats free. Setters below call this automatically;
-- callers rarely need to invoke it directly.
-- @treturn VectorIcon `self` for chaining.
function VectorIcon:refresh()
	if not self.path then
		return self
	end
	local handle = VectorIcon.imageHandle(self.iup, {
		path = self.path,
		size = self.size,
		color = self.color,
		rotation = self.rotation,
		scale = self.scale,
		offsetX = self.offsetX,
		offsetY = self.offsetY,
	})
	if handle then
		pcall(self.iup.SetAttribute, self.label, "IMAGE", handle)
	end
	return self
end

--- Switch to a different source SVG file and refresh.
-- @tparam string path Absolute path to the new `.svg` file.
-- @treturn VectorIcon `self` for chaining.
function VectorIcon:setPath(path)
	self.path = path
	return self:refresh()
end

--- Set a fixed hex fill/stroke color and refresh.
-- Clears any bound role; the icon will no longer recolor on theme switches.
-- @tparam string hex `"#RRGGBB"` hex color string.
-- @treturn VectorIcon `self` for chaining.
function VectorIcon:setColor(hex)
	self.role = nil
	self.color = hex
	return self:refresh()
end

--- Bind the icon to a semantic color role and refresh.
-- The icon will recolor automatically on every future theme switch via `_onThemeApply`.
-- @tparam string role Semantic role name (e.g. `"success"`, `"error"`, `"accent"`).
-- @treturn VectorIcon `self` for chaining.
function VectorIcon:setRole(role)
	self.role = role
	self.color = VectorIcon.roleColor(role)
	return self:refresh()
end

--- Set the render size and refresh.
-- Also updates the label's `RASTERSIZE` so layout space is reserved immediately.
-- @tparam number size New square pixel size.
-- @treturn VectorIcon `self` for chaining.
function VectorIcon:setSize(size)
	self.size = size
	pcall(self.iup.SetAttribute, self.label, "RASTERSIZE", self.size .. "x" .. self.size)
	return self:refresh()
end

--- Set the clockwise rotation in degrees and refresh.
-- @tparam[opt=0] number degrees Rotation angle.
-- @treturn VectorIcon `self` for chaining.
function VectorIcon:setRotation(degrees)
	self.rotation = degrees or 0
	return self:refresh()
end

--- Set the zoom scale within the canvas and refresh.
-- @tparam[opt=1.0] number zoom Scale factor (`1.0` = fit to canvas exactly).
-- @treturn VectorIcon `self` for chaining.
function VectorIcon:setScale(zoom)
	self.scale = zoom or 1.0
	return self:refresh()
end

--- Set a pixel nudge from the centered position and refresh.
-- An optical-alignment escape hatch for pixel-perfect placement next to text.
-- @tparam[opt=0] number x Horizontal pixel offset.
-- @tparam[opt=0] number y Vertical pixel offset.
-- @treturn VectorIcon `self` for chaining.
function VectorIcon:setOffset(x, y)
	self.offsetX = x or 0
	self.offsetY = y or 0
	return self:refresh()
end

--- Switch path and fixed color together in one refresh.
-- Clears any bound role (this is an explicit fixed color, equivalent to `setColor`).
-- @tparam[opt] string path Absolute path to the new `.svg` file; `nil` keeps the current path.
-- @tparam[opt] string color `"#RRGGBB"` hex color; `nil` keeps the current color.
-- @treturn VectorIcon `self` for chaining.
function VectorIcon:setIcon(path, color)
	self.path = path or self.path
	self.role = nil
	self.color = color or self.color
	return self:refresh()
end

--- Switch path and semantic role together in one refresh.
-- The icon stays theme-aware and recolors on future theme switches.
-- Used by `StatusIcon` for its state transitions.
-- @tparam[opt] string path Absolute path to the new `.svg` file; `nil` keeps the current path.
-- @tparam[opt] string role Semantic role name; `nil` keeps the current role.
-- @treturn VectorIcon `self` for chaining.
function VectorIcon:setIconRole(path, role)
	self.path = path or self.path
	self.role = role or self.role
	self.color = self.role and VectorIcon.roleColor(self.role) or self.color
	return self:refresh()
end

--- Update the hover tooltip text.
-- @tparam string text New tooltip string.
-- @treturn VectorIcon `self` for chaining.
function VectorIcon:setTooltip(text)
	pcall(self.iup.SetAttribute, self.label, "TIP", tostring(text or ""))
	return self
end

--- Begin a continuous rotation animation.
-- Safe to call while already spinning (no-op). Optionally sets the tooltip first.
-- @tparam[opt=12] number fps Target visual update rate (frames per second).
-- @tparam[opt] string tooltip Tooltip shown while spinning.
-- @tparam[opt] string direction `"ccw"` for counter-clockwise; default is clockwise.
-- @treturn VectorIcon `self` for chaining.
function VectorIcon:spin(fps, tooltip, direction)
	if tooltip ~= nil then
		self:setTooltip(tooltip)
	end
	if self._spinning then
		return self
	end
	-- Keep spinner footprint stable across all frames: use a non-zero angle
	-- from the first frame onward so render_to_buffer always applies the same
	-- rotation-safe margin while spinning.
	if self.rotation == 0 then
		self.rotation = 360
		self:refresh()
	end
	self._spinning = true
	-- Rotation step per frame: negative spins counter-clockwise. +30 (clockwise)
	-- keeps the historical build-spinner direction as the default.
	self._spinStep = ((direction == "ccw") or (direction == -1)) and -30 or 30
	if not self._timer then
		local this = self
		self._timer = self.iup.timer({ RUN = "NO" })
		function self._timer:action_cb()
			if this._spinning then
				local next_rot = (this.rotation + (this._spinStep or 30)) % 360
				if next_rot == 0 then next_rot = 360 end
				this.rotation = next_rot
				this:refresh()
			end
			return this.iup.DEFAULT
		end
	end
	pcall(self.iup.SetAttribute, self._timer, "TIME", tostring(math.floor(1000 / (fps or 12))))
	pcall(self.iup.SetAttribute, self._timer, "RUN", "YES")
	return self
end

--- Stop spinning and optionally settle on a final path/color/tooltip.
-- Rotation resets to 0 so the settled glyph renders upright.
--
-- Overload forms:
--
-- * `stopSpin()` — stop and re-render at rotation 0.
-- * `stopSpin(color, tip?)` — stop and apply a new fixed hex color.
-- * `stopSpin(path, color, tip?)` — stop, switch path, and apply a new fixed color.
--
-- @tparam[opt] string finalPathOrColor Hex color `"#RRGGBB"` or an absolute SVG path.
-- @tparam[opt] string colorOrTooltip Hex color (when `finalPathOrColor` is a path) or tooltip.
-- @tparam[opt] string tooltip Tooltip string (when both path and color are given).
-- @treturn VectorIcon `self` for chaining.
function VectorIcon:stopSpin(finalPathOrColor, colorOrTooltip, tooltip)
	self._spinning = false
	if self._timer then
		pcall(self.iup.SetAttribute, self._timer, "RUN", "NO")
	end
	self.rotation = 0
	if finalPathOrColor and colorOrTooltip and tostring(colorOrTooltip):sub(1, 1) == "#" then
		-- stopSpin(path, color, tip?)
		self:setIcon(finalPathOrColor, colorOrTooltip)
		if tooltip ~= nil then
			self:setTooltip(tooltip)
		end
	elseif finalPathOrColor then
		-- stopSpin(color, tip?)
		self:setColor(finalPathOrColor)
		if colorOrTooltip ~= nil then
			self:setTooltip(colorOrTooltip)
		end
	else
		self:refresh()
	end
	return self
end

--- Return whether the spinner is currently running.
-- @treturn boolean `true` while a spin animation is active.
function VectorIcon:isSpinning()
	return self._spinning
end

VectorIcon.available = true
return VectorIcon
