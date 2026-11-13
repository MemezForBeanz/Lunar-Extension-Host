--- The draw context widgets paint with, and IUP's `iup.Draw*` canvas API on top of it.
--
-- One context (`dc`) exists per frame. Its calls are IUP's drawing vocabulary
-- (`iupdrvDrawRectangle`, `iupFlatDrawBox`, `iupdrvDrawText`...) expressed in client
-- pixels and handed to the backend's ImDrawList calls. It adds what IUP's drivers did
-- implicitly: an alpha stack (for transitions), clip culling, text alignment, wrapping
-- and ellipsis the way IUP lays them out, and recording, so a part of the window can
-- be captured as a list of calls and replayed by the compositor.
--
-- @module core.imgui.Draw
local Color = require("core.imgui.Color")
local Fonts = require("core.imgui.Fonts")
local Element = require("core.imgui.Element")

local M = {}

local CORNER_TL, CORNER_TR, CORNER_BL, CORNER_BR, CORNER_NONE = 16, 32, 64, 128, 256

local DC = {}
DC.__index = DC
M.DC = DC

-- Recordings can outlive both an image mutation and the upload cache entry.
-- Retain only the texture IDs they actually reference, releasing them on explicit
-- snapshot release or GC. This also makes byte-budget eviction safe mid-frame.
local function retain_recording(rec, B, op, id)
	if (op ~= "image" and op ~= "image_rounded") or not B.texture_retain then return end
	local pins = rec._textures
	if not pins then
		pins = {}; rec._textures = pins
		local token = newproxy(true)
		getmetatable(token).__gc = function()
			for tex in pairs(pins) do pcall(B.texture_free, tex); pins[tex] = nil end
		end
		rec._texture_guard = token
	end
	if not pins[id] and B.texture_retain(id) then pins[id] = B end
end

function M.releaseRecording(rec)
	if not rec then return end
	for id,B in pairs(rec._textures or {}) do B.texture_free(id); rec._textures[id] = nil end
	rec._texture_guard, rec._textures = nil, nil
end

--- A new draw context over `backend`.
function M.new(backend)
	return setmetatable({
		B = backend, ox = 0, oy = 0, alpha = 1, alphas = {}, clips = {}, offsets = {},
		rec = nil, recs = {}, layer_index = 0,
		cx1 = -1e9, cy1 = -1e9, cx2 = 1e9, cy2 = 1e9,
	}, DC)
end

--- Reset per-frame state (called by the runtime before painting).
function DC:begin(w, h)
	self.ox, self.oy, self.alpha = 0, 0, 1
	self.alphas, self.clips, self.offsets = {}, {}, {}
	self.cx1, self.cy1, self.cx2, self.cy2 = 0, 0, w or 1e9, h or 1e9
	self.layer_index = 0
	self.surfaces, self.surface_id = nil, 0
	if self.B.layer then self.B.layer(0) end
end

local function corner_flags(radius, corners)
	if not radius or radius <= 0 then return CORNER_NONE end
	if not corners then return 0 end
	local f = 0
	if corners.tl then f = f + CORNER_TL end
	if corners.tr then f = f + CORNER_TR end
	if corners.bl then f = f + CORNER_BL end
	if corners.br then f = f + CORNER_BR end
	if f == 0 then return CORNER_NONE end
	return f
end
M.corner_flags = corner_flags

function DC:_color(c)
	if type(c) ~= "number" then c = Color.parse(c) end
	if not c then return nil end
	if self.alpha < 1 then c = Color.alpha(c, self.alpha) end
	return c
end

-- Every primitive goes through _emit so a recording sees it, in absolute coordinates.
function DC:_emit(op, ...)
	local rec = self.rec
	if rec then
		retain_recording(rec, self.B, op, ...)
		rec[#rec + 1] = { op, ... }
		if not self.rec_draw then return end
	end
	local fn = self.B[op]
	if fn then fn(...) end
end

--- Is any part of the rect inside the current clip? Widgets and the runtime cull with it.
function DC:visible(x, y, w, h)
	x, y = x + self.ox, y + self.oy
	return x < self.cx2 and y < self.cy2 and x + w > self.cx1 and y + h > self.cy1
end

function DC:fill(x, y, w, h, color, opts)
	local c = self:_color(color)
	if not c or w <= 0 or h <= 0 then return end
	x, y = x + self.ox, y + self.oy
	local r = opts and opts.radius or 0
	self:_emit("rect_filled", x, y, x + w, y + h, c, r, corner_flags(r, opts and opts.corners))
end

function DC:rect(x, y, w, h, color, opts)
	local c = self:_color(color)
	if not c or w <= 0 or h <= 0 then return end
	x, y = x + self.ox, y + self.oy
	local r = opts and opts.radius or 0
	local t = opts and opts.thickness or 1
	self:_emit("rect", x, y, x + w, y + h, c, r, t, corner_flags(r, opts and opts.corners))
end

--- A gradient from c1 to c2. With a radius, ImGui has no rounded multi-colour rect, so
-- the gradient is clipped by drawing it as horizontal or vertical slices inside the
-- rounded shape (each slice's ends are shortened to the corner arc).
function DC:gradient(x, y, w, h, c1, c2, direction, opts)
	local a, b = self:_color(c1), self:_color(c2)
	if not a or w <= 0 or h <= 0 then return end
	if not b then return self:fill(x, y, w, h, a, opts) end
	local r = opts and opts.radius or 0
	local horizontal = direction == "HORIZONTAL"
	if r <= 0 then
		x, y = x + self.ox, y + self.oy
		if horizontal then
			self:_emit("rect_gradient", x, y, x + w, y + h, a, b, b, a)
		else
			self:_emit("rect_gradient", x, y, x + w, y + h, a, a, b, b)
		end
		return
	end
	r = math.min(r, w / 2, h / 2)
	local steps = math.max(1, math.floor(horizontal and w or h))
	for i = 0, steps - 1 do
		local t = steps > 1 and i / (steps - 1) or 0
		local c = Color.mix(a, b, t)
		if horizontal then
			local inset = 0
			if i < r then inset = r - math.sqrt(math.max(0, r * r - (r - i - 0.5) ^ 2))
			elseif i > w - r then local d = i - (w - r) + 0.5; inset = r - math.sqrt(math.max(0, r * r - d * d)) end
			self:_emit("rect_filled", x + self.ox + i, y + self.oy + inset, x + self.ox + i + 1, y + self.oy + h - inset, c, 0, CORNER_NONE)
		else
			local inset = 0
			if i < r then inset = r - math.sqrt(math.max(0, r * r - (r - i - 0.5) ^ 2))
			elseif i > h - r then local d = i - (h - r) + 0.5; inset = r - math.sqrt(math.max(0, r * r - d * d)) end
			self:_emit("rect_filled", x + self.ox + inset, y + self.oy + i, x + self.ox + w - inset, y + self.oy + i + 1, c, 0, CORNER_NONE)
		end
	end
end

function DC:line(x1, y1, x2, y2, color, thickness)
	local c = self:_color(color)
	if not c then return end
	self:_emit("line", x1 + self.ox, y1 + self.oy, x2 + self.ox, y2 + self.oy, c, thickness or 1)
end

function DC:circle(cx, cy, r, color, opts)
	local c = self:_color(color)
	if not c then return end
	local filled = opts and opts.filled
	self:_emit("circle", cx + self.ox, cy + self.oy, r, c, filled and 0 or (opts and opts.thickness or 1), opts and opts.segments or 0)
end

function DC:poly(points, color, opts)
	local c = self:_color(color)
	if not c or #points < 4 then return end
	local pts = {}
	for i = 1, #points, 2 do
		pts[i] = points[i] + self.ox
		pts[i + 1] = points[i + 1] + self.oy
	end
	self:_emit("poly", pts, c, opts and opts.filled or false, opts and opts.thickness or 1)
end

-- Text -----------------------------------------------------------------------------

local wrap_cache = {}
local wrap_count = 0

local function split_lines(text)
	local lines = {}
	for line in (text .. "\n"):gmatch("(.-)\r?\n") do lines[#lines + 1] = line end
	return lines
end

-- One line's width. With GDI available it is GDI's (GetTextExtentPoint32 with the font IUP
-- would have made), so natural sizes, wrap points and ellipses fall where IUP put them.
local function measure(font, s)
	if s == "" then return 0 end
	local width = font:measure(s)
	return width
end

--- Word-wrap `text` to `width` the way IUP's DT_WORDBREAK does: break at spaces, and
-- break a single word that does not fit at character boundaries.
function M.wrap(font, text, width)
	local key = font.str .. "\0" .. width .. "\0" .. text
	local hit = wrap_cache[key]
	if hit then return hit end
	local out = {}
	for _, line in ipairs(split_lines(text)) do
		if line == "" or measure(font, line) <= width then
			out[#out + 1] = line
		else
			local current = ""
			for word, space in line:gmatch("(%S*)(%s*)") do
				if word == "" and space == "" then break end
				local candidate = current .. word
				if current ~= "" and measure(font, candidate) > width then
					out[#out + 1] = current:gsub("%s+$", "")
					current = word .. space
				else
					current = candidate .. space
				end
				-- a word longer than the line
				while measure(font, current:gsub("%s+$", "")) > width and #current > 1 do
					local cut = #current
					while cut > 1 and measure(font, current:sub(1, cut)) > width do cut = cut - 1 end
					-- do not split inside a UTF-8 sequence
					while cut > 1 and current:byte(cut + 1) and current:byte(cut + 1) >= 128 and current:byte(cut + 1) < 192 do cut = cut - 1 end
					out[#out + 1] = current:sub(1, cut)
					current = current:sub(cut + 1)
				end
			end
			if current ~= "" then out[#out + 1] = (current:gsub("%s+$", "")) end
		end
	end
	wrap_count = wrap_count + 1
	if wrap_count > 1024 then wrap_cache = {}; wrap_count = 0 end
	wrap_cache[key] = out
	return out
end

--- Shorten `s` to fit `width` with IUP's "..." ellipsis.
function M.ellipsize(font, s, width)
	if measure(font, s) <= width then return s end
	local dots = "..."
	local dw = measure(font, dots)
	if dw >= width then return "" end
	local lo, hi = 0, #s
	while lo < hi do
		local mid = math.floor((lo + hi + 1) / 2)
		if measure(font, s:sub(1, mid)) + dw <= width then lo = mid else hi = mid - 1 end
	end
	while lo > 0 and s:byte(lo + 1) and s:byte(lo + 1) >= 128 and s:byte(lo + 1) < 192 do lo = lo - 1 end
	return s:sub(1, lo) .. dots
end

local ALIGN = { ALEFT = "left", ACENTER = "center", ARIGHT = "right", LEFT = "left",
	CENTER = "center", RIGHT = "right", ATOP = "top", ABOTTOM = "bottom", TOP = "top", BOTTOM = "bottom" }
M.ALIGN = ALIGN

--- Measure text as IUP does for a control's natural size (each line, widest line wins).
function DC:measure(str, font, wrap)
	font = font or Fonts.get()
	if wrap and wrap > 0 then
		local lines = M.wrap(font, str or "", wrap)
		local _, ch = font:charsize()
		local w = 0
		for _, l in ipairs(lines) do w = math.max(w, measure(font, l)) end
		return math.ceil(w), ch * math.max(1, #lines)
	end
	return M.measureText(font, str)
end

function M.measureText(font, str)
	str = str or ""
	local _, ch = font:charsize()
	local w, n = 0, 0
	for _, l in ipairs(split_lines(str)) do
		n = n + 1
		w = math.max(w, measure(font, l))
	end
	return math.ceil(w), ch * math.max(1, n)
end

--- Draw text in a box. `opts.align` left|center|right (or IUP's ALEFT...),
-- `opts.valign` top|center|bottom, `opts.wrap`, `opts.ellipsis`, `opts.clip`.
function DC:text(str, x, y, w, h, color, font, opts)
	if str == nil or str == "" then return end
	local c = self:_color(color)
	if not c then return end
	font = font or Fonts.get()
	opts = opts or {}
	local align = ALIGN[opts.align] or opts.align or "left"
	local valign = ALIGN[opts.valign] or opts.valign or "top"
	local lines
	if opts.wrap and w and w > 0 then lines = M.wrap(font, str, w) else lines = split_lines(str) end
	local _, lh = font:charsize()
	local total = lh * #lines
	local ty = y
	if h and valign == "center" then ty = y + math.floor((h - total) / 2)
	elseif h and valign == "bottom" then ty = y + h - total end
	local clip = opts.clip and w and h
	if clip then self:clip_push(x, y, w, h) end
	for i, line in ipairs(lines) do
		if line ~= "" then
			if opts.ellipsis and w then line = M.ellipsize(font, line, w) end
			local lw = measure(font, line)
			local lx = x
			if w and align == "center" then lx = x + math.floor((w - lw) / 2)
			elseif w and align == "right" then lx = x + w - lw end
			local ly = ty + (i - 1) * lh
			self:_emit("text", font.id, font.px, lx + self.ox, ly + self.oy, c, line, 0,
				self.cx1, self.cy1, self.cx2, self.cy2, font.gid or -1)
			if font.underline or font.strikeout then
				local asc = font:ascent() or lh * 0.8
				if font.underline then
					self:_emit("line", lx + self.ox, ly + self.oy + asc + 1.5, lx + self.ox + lw, ly + self.oy + asc + 1.5, c, 1)
				end
				if font.strikeout then
					self:_emit("line", lx + self.ox, ly + self.oy + lh / 2, lx + self.ox + lw, ly + self.oy + lh / 2, c, 1)
				end
			end
		end
	end
	if clip then self:clip_pop() end
end

-- Images ---------------------------------------------------------------------------

--- An image element from an attribute value: a handle, a SetHandle name, or nil.
function M.resolveImage(value)
	if value == nil then return nil end
	if Element.is(value) then return value end
	local h = Element.named[value]
	if h then return h end
	return nil
end

--- The texture of an image element, uploaded on first use. Returns tex, w, h.
function M.texture(img, B)
	local st = Element.state(img)
	if not st then return nil end
	local d = st.data
	if d.tex and d.tex_backend == B then return d.tex, d.w, d.h end
	if d.tex and d.tex_backend and d.tex_backend.texture_free then
		d.tex_backend.texture_free(d.tex)
	end
	d.tex, d.tex_backend = nil, nil
	local w = tonumber(Element.getAttribute(img, "WIDTH")) or d.w
	local h = tonumber(Element.getAttribute(img, "HEIGHT")) or d.h
	local pixels = d.pixels
	if not (w and h and pixels and B.texture) then return nil end
	local tex = B.texture(pixels, w, h)
	if not tex then return nil end
	d.tex, d.w, d.h, d.tex_backend = tex, w, h, B
	return tex, w, h
end

function M.imageSize(img)
	if not img then return 0, 0 end
	local st = Element.state(img)
	if not st then return 0, 0 end
	local w = tonumber(Element.getAttribute(img, "WIDTH")) or st.data.w or 0
	local h = tonumber(Element.getAttribute(img, "HEIGHT")) or st.data.h or 0
	return w, h
end

--- Draw an image element. Without w/h it draws at its own size.
function DC:image(img, x, y, w, h, opts)
	img = M.resolveImage(img)
	if not img then return end
	local tex, iw, ih = M.texture(img, self.B)
	if not tex then return end
	w, h = w or iw, h or ih
	local tint = 0xFFFFFFFF
	local a = self.alpha * (opts and opts.alpha or 1)
	if opts and opts.inactive then a = a * 0.5 end
	if opts and opts.tint then tint = Color.parse(opts.tint) or tint end
	if a < 1 then tint = Color.alpha(tint, a) end
	x, y = x + self.ox, y + self.oy
	self:_emit("image", tex, x, y, x + w, y + h, 0, 0, 1, 1, tint)
end

-- Provider pixels (iupdrvDrawBits) ------------------------------------------------------
--
-- The fork's grid and rows ask a Lua provider for 32-bit premultiplied BGRA pixels, top row
-- first, and draw them at their own size. The provider keeps the memory, and its cache may
-- free a buffer and hand the same address to another image later, so a texture is keyed by
-- the address, the geometry and a sample of the pixels themselves.

local bits_cache = setmetatable({}, { __mode = "k" })   -- backend -> { map, order }
local BITS_KEEP, BITS_BYTES = 384, 8 * 1024 * 1024

function M.clearBitsCache(B)
	local cache = bits_cache[B]
	if not cache then return end
	for _,entry in pairs(cache.map) do if B.texture_free then B.texture_free(entry.tex) end end
	bits_cache[B] = nil
end

function M.bitsCacheStats(B)
	local c = bits_cache[B]
	return {entries=c and c.count or 0,bytes=c and c.bytes or 0,max_bytes=BITS_BYTES,max_entries=BITS_KEEP}
end

local okffi, ffi = pcall(require, "ffi")
local function fingerprint(ptr, w, h, stride)
	if type(ptr) == "string" then return ptr end
	if not okffi then return tostring(ptr) end
	local p = ffi.cast("const uint32_t*", ptr)
	local words = stride / 4
	local parts = { tostring(ffi.cast("uintptr_t", p)) }
	-- nine samples on a 3x3 lattice: enough to notice a different poster at the same address
	for sy = 0, 2 do
		local y = math.floor((h - 1) * sy / 2)
		for sx = 0, 2 do
			local x = math.floor((w - 1) * sx / 2)
			parts[#parts + 1] = tostring(p[y * words + x])
		end
	end
	return table.concat(parts, ":")
end

--- The texture for a provider's pixels, uploading them the first time they are seen.
function M.bitsTexture(B, ptr, w, h, stride)
	if not (B and B.texture_bits and ptr and w and h and w > 0 and h > 0) then return nil end
	stride = stride and stride > 0 and stride or w * 4
	local cache = bits_cache[B]
	if not cache then cache = { map = {}, count = 0, bytes = 0 }; bits_cache[B] = cache end
	local key = fingerprint(ptr, w, h, stride) .. "@" .. w .. "x" .. h .. "/" .. stride
	local function unlink(entry)
		if entry.prev then entry.prev.next = entry.next else cache.first = entry.next end
		if entry.next then entry.next.prev = entry.prev else cache.last = entry.prev end
	end
	local function recent(entry)
		entry.prev, entry.next = nil, cache.first
		if cache.first then cache.first.prev = entry else cache.last = entry end
		cache.first = entry
	end
	local entry = cache.map[key]
	if entry then unlink(entry); recent(entry); return entry.tex end
	local tex = B.texture_bits(ptr, w, h, stride, true)
	if not tex then return nil end
	entry = {tex=tex,key=key,bytes=w*h*4+#key+128}
	cache.map[key] = entry; recent(entry)
	cache.count, cache.bytes = cache.count+1, cache.bytes+entry.bytes
	-- Keep the newly requested texture until the caller can record/use it. A single
	-- oversized live image is permitted; unrelated older uploads are evicted.
	while cache.count > 1 and (cache.count > BITS_KEEP or cache.bytes > BITS_BYTES) do
		local old = cache.last; unlink(old);cache.map[old.key] = nil
		cache.count, cache.bytes = cache.count-1, cache.bytes-old.bytes
		if B.texture_free then B.texture_free(old.tex) end
	end
	return tex
end

--- iupdrvDrawBits: provider pixels at x, y at their own size. `opts.radius` rounds the
-- corners as the grid's corner tiles do.
function DC:bits(ptr, w, h, stride, x, y, opts)
	local tex = M.bitsTexture(self.B, ptr, w, h, stride)
	if not tex then return false end
	local tint = 0xFFFFFFFF
	if self.alpha < 1 then tint = Color.alpha(tint, self.alpha) end
	x, y = x + self.ox, y + self.oy
	local radius = opts and opts.radius or 0
	if radius > 0 and self.B.image_rounded then
		self:_emit("image_rounded", tex, x, y, x + w, y + h, tint, radius)
	else
		self:_emit("image", tex, x, y, x + w, y + h, 0, 0, 1, 1, tint)
	end
	return true
end

-- State stacks -------------------------------------------------------------------------

function DC:clip_push(x, y, w, h)
	x, y = x + self.ox, y + self.oy
	local stack = self.clips
	stack[#stack + 1] = { self.cx1, self.cy1, self.cx2, self.cy2 }
	self.cx1 = math.max(self.cx1, x)
	self.cy1 = math.max(self.cy1, y)
	self.cx2 = math.min(self.cx2, x + w)
	self.cy2 = math.min(self.cy2, y + h)
	if self.cx2 < self.cx1 then self.cx2 = self.cx1 end
	if self.cy2 < self.cy1 then self.cy2 = self.cy1 end
	self:_emit("clip_push", self.cx1, self.cy1, self.cx2, self.cy2)
end

function DC:clip_pop()
	local stack = self.clips
	local top = table.remove(stack)
	if not top then return end
	self.cx1, self.cy1, self.cx2, self.cy2 = top[1], top[2], top[3], top[4]
	self:_emit("clip_pop")
end

function DC:alpha_push(a)
	self.alphas[#self.alphas + 1] = self.alpha
	self.alpha = self.alpha * a
end

function DC:alpha_pop()
	self.alpha = table.remove(self.alphas) or 1
end

function DC:offset_push(dx, dy)
	self.offsets[#self.offsets + 1] = { self.ox, self.oy }
	self.ox, self.oy = self.ox + dx, self.oy + dy
end

function DC:offset_pop()
	local o = table.remove(self.offsets)
	if o then self.ox, self.oy = o[1], o[2] end
end

--- Draw on a secondary dialog's own window (the backend surface `id`) until surface_end.
-- (x, y, w, h) is that window's client in main-window coordinates: culling and clipping
-- start from it, not from the main window, since the dialog may lie outside the main one.
function DC:surface(id, x, y, w, h)
	local stack = self.surfaces
	if not stack then stack = {}; self.surfaces = stack end
	stack[#stack + 1] = { self.cx1, self.cy1, self.cx2, self.cy2, self.surface_id or 0 }
	self.cx1, self.cy1, self.cx2, self.cy2 = x, y, x + w, y + h
	self.surface_id = id
	self:_emit("surface", id)
end

function DC:surface_end()
	local top = self.surfaces and table.remove(self.surfaces)
	if not top then return end
	self.cx1, self.cy1, self.cx2, self.cy2 = top[1], top[2], top[3], top[4]
	self.surface_id = top[5]
	self:_emit("surface", top[5])
end

function DC:layer(name)
	local n = (name == "overlay" or name == 1) and 1 or 0
	self.layer_index = n
	self:_emit("layer", n)
end

--- Start recording. With `draw_too`, calls are drawn as well as recorded.
function DC:record(draw_too)
	self.recs[#self.recs + 1] = { self.rec, self.rec_draw }
	self.rec = {}
	self.rec_draw = draw_too and true or false
end

--- Stop recording and return the list of calls.
function DC:stop()
	local list = self.rec
	local prev = table.remove(self.recs)
	if prev then self.rec, self.rec_draw = prev[1], prev[2] else self.rec, self.rec_draw = nil, nil end
	return list or {}
end

-- Which arguments of each backend call are x and y coordinates.
local XS = {
	rect_filled = { 1, 3 }, rect = { 1, 3 }, rect_gradient = { 1, 3 }, line = { 1, 3 },
	circle = { 1 }, text = { 3, 8, 10 }, image = { 2, 4 }, clip_push = { 1, 3 },
	image_rounded = { 2, 4 },
}
local YS = {
	rect_filled = { 2, 4 }, rect = { 2, 4 }, rect_gradient = { 2, 4 }, line = { 2, 4 },
	circle = { 2 }, text = { 4, 9, 11 }, image = { 3, 5 }, clip_push = { 2, 4 },
	image_rounded = { 3, 5 },
}
local COLOR_ARG = { rect_filled = 5, rect = 5, line = 5, circle = 4, text = 5, poly = 2, image = 10, image_rounded = 6 }

--- Replay a recording shifted by (dx, dy) with its alpha scaled by `alpha`.
function DC:replay(list, dx, dy, alpha)
	dx, dy, alpha = dx or 0, dy or 0, alpha or 1
	alpha = alpha * self.alpha
	local args = {}
	for _, cmd in ipairs(list) do
		local op = cmd[1]
		if dx == 0 and dy == 0 and alpha == 1 then
			self:_emit(op, unpack(cmd, 2))
		else
		for i = #cmd, #args do args[i] = nil end
		for i = 2, #cmd do args[i-1] = cmd[i] end
		local xs, ys = XS[op], YS[op]
		if xs then
			for _, i in ipairs(xs) do args[i] = args[i] + dx end
			for _, i in ipairs(ys) do args[i] = args[i] + dy end
		elseif op == "poly" then
			local pts = {}
			for i = 1, #args[1], 2 do pts[i] = args[1][i] + dx; pts[i + 1] = args[1][i + 1] + dy end
			args[1] = pts
		end
		if alpha < 1 then
			local ci = COLOR_ARG[op]
			if ci and args[ci] then args[ci] = Color.alpha(args[ci], alpha) end
			if op == "rect_gradient" then
				for i = 5, 8 do args[i] = Color.alpha(args[i], alpha) end
			end
		end
		self:_emit(op, unpack(args))
		end
	end
end

-- iup.Draw* (canvas drawing inside ACTION) -------------------------------------------

--- The context and canvas the runtime is painting right now.
M.current = nil        -- dc
local canvas_stack = {}

--- Called by the canvas class around its ACTION callback.
function M.enterCanvas(el, dc)
	local st = Element.state(el)
	canvas_stack[#canvas_stack + 1] = { el = el, st = st, dc = dc }
end

function M.leaveCanvas()
	table.remove(canvas_stack)
end

local function ctx(h)
	for i = #canvas_stack, 1, -1 do
		if canvas_stack[i].el == h then return canvas_stack[i] end
	end
	return canvas_stack[#canvas_stack]
end

local function attr(h, name) return Element.getAttribute(h, name) end

function M.DrawBegin(h)
	local c = ctx(h)
	if not c then return end
	c.dc:clip_push(c.st.x, c.st.y, c.st.w, c.st.h)
	c.clips = 1
end

function M.DrawEnd(h)
	local c = ctx(h)
	if not c then return end
	while c.clips and c.clips > 0 do c.dc:clip_pop(); c.clips = c.clips - 1 end
end

function M.DrawGetSize(h)
	local st = Element.state(h)
	if not st then return 0, 0 end
	return st.w, st.h
end

local function drawcolor(h)
	return attr(h, "DRAWCOLOR") or "0 0 0"
end

local function linewidth(h) return tonumber(attr(h, "DRAWLINEWIDTH")) or 1 end

function M.DrawRectangle(h, x1, y1, x2, y2)
	local c = ctx(h)
	if not c then return end
	local ox, oy = c.st.x, c.st.y
	if x2 < x1 then x1, x2 = x2, x1 end
	if y2 < y1 then y1, y2 = y2, y1 end
	local style = attr(h, "DRAWSTYLE") or "STROKE"
	if style == "FILL" then
		c.dc:fill(ox + x1, oy + y1, x2 - x1 + 1, y2 - y1 + 1, drawcolor(h))
	else
		c.dc:rect(ox + x1, oy + y1, x2 - x1 + 1, y2 - y1 + 1, drawcolor(h), { thickness = linewidth(h) })
	end
end

function M.DrawRoundedRectangle(h, x1, y1, x2, y2, r)
	local c = ctx(h)
	if not c then return end
	local ox, oy = c.st.x, c.st.y
	local style = attr(h, "DRAWSTYLE") or "STROKE"
	local opts = { radius = r, thickness = linewidth(h) }
	if style == "FILL" then
		c.dc:fill(ox + x1, oy + y1, x2 - x1 + 1, y2 - y1 + 1, drawcolor(h), opts)
	else
		c.dc:rect(ox + x1, oy + y1, x2 - x1 + 1, y2 - y1 + 1, drawcolor(h), opts)
	end
end

function M.DrawLine(h, x1, y1, x2, y2)
	local c = ctx(h)
	if not c then return end
	local ox, oy = c.st.x, c.st.y
	local lw = linewidth(h)
	-- iupdrvDrawLine (GDI) sets whole pixels, both ends included. An anti-aliased ImGui
	-- line blends a 1px row to partial coverage and draws nothing for a single point,
	-- which left WorkspaceFrame's rounded junctions a shade off and their edge pixels
	-- missing. Straight lines are filled as exact pixel runs instead.
	if lw <= 1 and (y1 == y2 or x1 == x2) then
		local lx, ly = math.min(x1, x2), math.min(y1, y2)
		c.dc:fill(ox + lx, oy + ly, math.abs(x2 - x1) + 1, math.abs(y2 - y1) + 1, drawcolor(h))
		return
	end
	c.dc:line(ox + x1 + 0.5, oy + y1 + 0.5, ox + x2 + 0.5, oy + y2 + 0.5, drawcolor(h), lw)
end

function M.DrawPixel(h, x, y)
	local c = ctx(h)
	if not c then return end
	c.dc:fill(c.st.x + x, c.st.y + y, 1, 1, drawcolor(h))
end

function M.DrawArc(h, x1, y1, x2, y2, a1, a2)
	local c = ctx(h)
	if not c then return end
	local ox, oy = c.st.x, c.st.y
	local cx, cy = ox + (x1 + x2) / 2, oy + (y1 + y2) / 2
	local rx, ry = math.abs(x2 - x1) / 2, math.abs(y2 - y1) / 2
	local pts = {}
	local n = 32
	local filled = (attr(h, "DRAWSTYLE") or "STROKE") == "FILL"
	if filled then pts[1], pts[2] = cx, cy end
	for i = 0, n do
		-- IUP angles are counter-clockwise degrees from 3 o'clock, y up
		local a = math.rad(a1 + (a2 - a1) * i / n)
		pts[#pts + 1] = cx + rx * math.cos(a)
		pts[#pts + 1] = cy - ry * math.sin(a)
	end
	c.dc:poly(pts, drawcolor(h), { filled = filled, thickness = linewidth(h) })
end

function M.DrawEllipse(h, x1, y1, x2, y2) return M.DrawArc(h, x1, y1, x2, y2, 0, 360) end

function M.DrawPolygon(h, points, count)
	local c = ctx(h)
	if not c then return end
	local ox, oy = c.st.x, c.st.y
	local pts = {}
	count = count or (#points / 2)
	for i = 1, count * 2, 2 do
		pts[i] = ox + points[i]
		pts[i + 1] = oy + points[i + 1]
	end
	c.dc:poly(pts, drawcolor(h), { filled = (attr(h, "DRAWSTYLE") or "STROKE") == "FILL", thickness = linewidth(h) })
end

local function drawfont(h)
	return Fonts.get(attr(h, "DRAWFONT") or attr(h, "FONT"))
end

function M.DrawText(h, text, x, y, w, hh)
	local c = ctx(h)
	if not c then return end
	local ox, oy = c.st.x, c.st.y
	local font = drawfont(h)
	if w == nil or w <= 0 then w = nil end
	if hh == nil or hh <= 0 then hh = nil end
	local align = attr(h, "DRAWTEXTALIGNMENT") or "ALEFT"
	local wrap = attr(h, "DRAWTEXTWRAP") == "YES"
	local ellipsis = attr(h, "DRAWTEXTELLIPSIS") == "YES"
	local clip = attr(h, "DRAWTEXTCLIP") == "YES"
	local center = attr(h, "DRAWTEXTLAYOUTCENTER") == "YES"
	local tw, th = c.dc:measure(text, font, wrap and w or nil)
	local bw, bh = w or tw, hh or th
	c.dc:text(text, ox + x, oy + y, bw, bh, drawcolor(h), font, {
		align = align, valign = center and "center" or "top", wrap = wrap, ellipsis = ellipsis,
		clip = clip,
	})
end

function M.DrawGetTextSize(h, text)
	local font = drawfont(h)
	return M.measureText(font, text or "")
end

function M.DrawImage(h, name, x, y, w, hh)
	local c = ctx(h)
	if not c then return end
	local img = M.resolveImage(name)
	if not img then return end
	local iw, ih = M.imageSize(img)
	if not w or w <= 0 then w = iw end
	if not hh or hh <= 0 then hh = ih end
	c.dc:image(img, c.st.x + x, c.st.y + y, w, hh, { inactive = attr(h, "DRAWMAKEINACTIVE") == "YES" })
end

function M.DrawGetImageInfo(name)
	local img = M.resolveImage(name)
	if not img then return nil end
	local w, h = M.imageSize(img)
	return w, h, 32
end

function M.DrawSetClipRect(h, x1, y1, x2, y2)
	local c = ctx(h)
	if not c then return end
	c.dc:clip_push(c.st.x + x1, c.st.y + y1, x2 - x1 + 1, y2 - y1 + 1)
	c.clips = (c.clips or 0) + 1
end

function M.DrawGetClipRect(h)
	local c = ctx(h)
	if not c then return 0, 0, 0, 0 end
	local d = c.dc
	return d.cx1 - c.st.x, d.cy1 - c.st.y, d.cx2 - c.st.x - 1, d.cy2 - c.st.y - 1
end

function M.DrawResetClip(h)
	local c = ctx(h)
	if not c then return end
	while c.clips and c.clips > 1 do c.dc:clip_pop(); c.clips = c.clips - 1 end
end

function M.DrawParentBackground(h)
	local c = ctx(h)
	if not c then return end
	local parent = c.st.parent
	local bg = parent and Element.getAttribute(parent, "BGCOLOR") or Element.globals.DLGBGCOLOR
	c.dc:fill(c.st.x, c.st.y, c.st.w, c.st.h, bg)
end

function M.DrawFocusRect(h, x1, y1, x2, y2)
	local c = ctx(h)
	if not c then return end
	c.dc:rect(c.st.x + x1, c.st.y + y1, x2 - x1 + 1, y2 - y1 + 1, attr(h, "FOCUSCOLOR") or drawcolor(h), { thickness = 1 })
end

function M.DrawSelectRect(h, x1, y1, x2, y2)
	local c = ctx(h)
	if not c then return end
	c.dc:fill(c.st.x + x1, c.st.y + y1, x2 - x1 + 1, y2 - y1 + 1, Color.alpha(Color.parse(drawcolor(h)) or 0xFF000000, 0.35))
end

return M
