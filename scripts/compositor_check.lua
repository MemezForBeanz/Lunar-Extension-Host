-- Byte-exact C compositor versus an independent Lua reference and the stored goldens.
--
-- Default: every case must match the Lua reference AND its stored golden
-- (spec/fixtures/compositor/<case>.bgra, raw premultiplied BGRA). Nothing is written.
-- `--update`: regenerate the goldens, plus <case>.png previews (un-premultiplied,
-- since PNG alpha is straight) for looking at by eye.
local compositor = require("compositor")
local reference = require("scene_reference")
local bit = require("bit")
local repo = assert(os.getenv("LUNAR_REPO"), "LUNAR_REPO must name the repo root")
local out_dir = repo .. "/spec/fixtures/compositor/"
local update = false
for _, a in ipairs(arg or {}) do if a == "--update" then update = true end end

local function u32(n)
	n = n % 4294967296
	return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256,
		math.floor(n / 256) % 256, n % 256)
end

local crc_table = {}
for n = 0, 255 do
	local c = n
	for _ = 1, 8 do
		c = bit.band(c, 1) == 1 and bit.bxor(bit.rshift(c, 1), 0xedb88320) or bit.rshift(c, 1)
	end
	crc_table[n] = c
end

local function crc32(data)
	local c = 0xffffffff
	for i = 1, #data do
		local index = bit.band(bit.bxor(c, data:byte(i)), 255)
		c = bit.bxor(bit.rshift(c, 8), crc_table[index])
	end
	return bit.bxor(c, 0xffffffff) % 4294967296
end

local function chunk(kind, data)
	return u32(#data) .. kind .. data .. u32(crc32(kind .. data))
end

local function png(name, w, h, bgra)
	local rows = {}
	for y = 0, h - 1 do
		local row = { "\0" }
		for x = 0, w - 1 do
			local p = (y * w + x) * 4 + 1
			local b, g, r, a = bgra:byte(p, p + 3)
			-- Premultiplied to straight alpha (PNG's), rounded.
			if a > 0 and a < 255 then
				r = math.min(255, math.floor(r * 255 / a + 0.5))
				g = math.min(255, math.floor(g * 255 / a + 0.5))
				b = math.min(255, math.floor(b * 255 / a + 0.5))
			elseif a == 0 then
				r, g, b = 0, 0, 0
			end
			row[#row + 1] = string.char(r, g, b, a)
		end
		rows[#rows + 1] = table.concat(row)
	end
	local raw = table.concat(rows)
	local blocks = { "\120\001" }
	local a, b = 1, 0
	for i = 1, #raw do
		a = (a + raw:byte(i)) % 65521
		b = (b + a) % 65521
	end
	for start = 1, #raw, 65535 do
		local part = raw:sub(start, start + 65534)
		local len = #part
		blocks[#blocks + 1] = string.char(start + len - 1 == #raw and 1 or 0,
			len % 256, math.floor(len / 256), (65535 - len) % 256,
			math.floor((65535 - len) / 256)) .. part
	end
	blocks[#blocks + 1] = u32(b * 65536 + a)
	local file = assert(io.open(out_dir .. name .. ".png", "wb"))
	file:write("\137PNG\r\n\026\n", chunk("IHDR", u32(w) .. u32(h) .. "\008\006\000\000\000"),
		chunk("IDAT", table.concat(blocks)), chunk("IEND", ""))
	file:close()
end

local source_bytes = table.concat({
	string.char(0, 0, 0, 0), string.char(0, 0, 255, 255),
	string.char(0, 128, 0, 128), string.char(255, 0, 0, 255),
	string.char(32, 32, 32, 64), string.char(10, 20, 30, 128),
	string.char(200, 150, 100, 255), string.char(0, 0, 0, 0),
	string.char(0, 0, 100, 128), string.char(0, 255, 255, 255),
	string.char(0, 0, 0, 255), string.char(80, 40, 20, 128),
})
local snap = compositor.image(4, 3, source_bytes)
local ref_snap = { w = 4, h = 3, bytes = source_bytes }
local function image(x, y, alpha, extra)
	local s = { kind = "image", snap = snap, x = x, y = y, alpha = alpha }
	for k, v in pairs(extra or {}) do s[k] = v end
	return s
end
local function fill(x, y, w, h, color, alpha)
	return { kind = "fill", x = x, y = y, w = w, h = h, color = color, alpha = alpha }
end
local function rrect(radius)
	return { kind = "rrect", x = 1, y = 1, w = 9, h = 7,
		radius = radius, color = 0x55aaee, alpha = 0.7 }
end
local function stroke(thickness)
	return { kind = "stroke", x = 1, y = 1, w = 8, h = 6,
		thickness = thickness, color = 0xff8844, alpha = 0.5 }
end
local cases = {
	{ "empty", 7, 5, {} },
	{ "opaque_fill", 9, 7, { fill(0, 0, 9, 7, 0x123456, 1) } },
	{ "half_fill", 9, 7, { fill(0, 0, 9, 7, 0x40a0e0, 0.5) } },
	{ "overlap", 9, 7, { fill(0, 0, 7, 7, 0xff0000, 0.5), fill(3, 1, 6, 5, 0x00ff00, 0.5) } },
	{ "rrect_0", 11, 9, { rrect(0) } },
	{ "rrect_1", 11, 9, { rrect(1) } },
	{ "rrect_8", 11, 9, { rrect(8) } },
	{ "rrect_large", 11, 9, { rrect(2147483647) } },
	{ "stroke_1", 11, 9, { stroke(1) } },
	{ "stroke_3", 11, 9, { stroke(3) } },
	{ "image_inside", 9, 7, { image(2, 2, 1) } },
	{ "image_negative", 9, 7, { image(-2, -1, 1) } },
	{ "image_subrect", 9, 7, { image(3, 1, 1, { sx = 1, sy = 1, sw = 2, sh = 2 }) } },
	{ "image_clip", 9, 7, { image(2, 2, 1, { clip = { x = -2, y = 3, w = 6, h = 8 } }) } },
	{ "image_alpha_0", 9, 7, { image(2, 2, 0) } },
	{ "image_alpha_half", 9, 7, { image(2, 2, 0.5) } },
	{ "image_over_fill", 9, 7, { fill(0, 0, 9, 7, 0x223344, 0.5), image(2, 2, 0.75) } },
	{ "off_surface", 9, 7, { fill(-20, 2, 3, 3, 0xffffff, 1) } },
	{ "one_pixel", 1, 1, { fill(0, 0, 1, 1, 0xabcdef, 0.5) } },
	{ "odd_sizes", 13, 5, { fill(1, 1, 11, 3, 0xabcdef, 0.5), stroke(1) } },
	-- Astra's overflow repro: a huge rounded rect clipped to a tiny surface. The
	-- corner radius is capped at 1<<20, so the corner pixel is outside the curve.
	{ "rrect_huge_corner", 1, 1, { { kind = "rrect", x = 0, y = 0, w = 1000000000, h = 1000000000,
		radius = 500000000, color = 0xffffff, alpha = 1 } } },
	{ "rrect_huge_inside", 3, 3, { { kind = "rrect", x = -400000000, y = -400000000,
		w = 1000000000, h = 1000000000, radius = 500000000, color = 0x336699, alpha = 1 } } },
}

local function read_file(path)
	local f = io.open(path, "rb")
	if not f then return nil end
	local data = f:read("*a")
	f:close()
	return data
end

for _, case in ipairs(cases) do
	local name, w, h, sprites = case[1], case[2], case[3], case[4]
	local native_scene, ref_scene = { w = w, h = h }, { w = w, h = h }
	for i, s in ipairs(sprites) do
		native_scene[i] = s
		local copy = {}
		for k, v in pairs(s) do copy[k] = v end
		if copy.snap then copy.snap = ref_snap end
		ref_scene[i] = copy
	end
	local actual = compositor.render(native_scene):bytes()
	local expected = reference.render(ref_scene)
	if actual ~= expected then
		for i = 1, #actual do
			if actual:byte(i) ~= expected:byte(i) then
				local pixel = math.floor((i - 1) / 4)
				error(string.format("%s: first differing pixel (%d,%d), channel %d: C=%d Lua=%d",
					name, pixel % w, math.floor(pixel / w), (i - 1) % 4,
					actual:byte(i), expected:byte(i)))
			end
		end
	end
	if update then
		local f = assert(io.open(out_dir .. name .. ".bgra", "wb"))
		f:write(actual)
		f:close()
		png(name, w, h, actual)
		print("updated: " .. name)
	else
		local golden = read_file(out_dir .. name .. ".bgra")
		if golden == nil then error(name .. ": no golden (run with --update to create it)") end
		if golden ~= actual then error(name .. ": differs from its stored golden") end
		print("identical: " .. name)
	end
end
if update then
	print(string.format("Updated %d goldens and PNG previews in %s", #cases, out_dir))
else
	print(string.format("All %d compositor scenes match the Lua reference and their goldens", #cases))
end

local function bench(w, h, scrim)
	local scene = { w = w, h = h, fill(0, 0, w, h, 0x000000, 0.5) }
	if not scrim then
		local bytes = string.rep(string.char(50, 100, 150, 200), w * h)
		local large = compositor.image(w, h, bytes)
		scene[#scene + 1] = { kind = "image", snap = large, x = 0, y = 0, alpha = 1 }
		for n = 1, 3 do
			scene[#scene + 1] = { kind = "rrect", x = n * 80, y = n * 70,
				w = 300, h = 130, radius = 24, color = 0x445566, alpha = 0.7 }
		end
	end
	local start = os.clock()
	for _ = 1, 3 do compositor.render(scene) end
	print(string.format("benchmark %dx%d %s: %.2f ms/render (CPU time, 3 renders)",
		w, h, scrim and "scrim" or "fill+image+3 rrects", (os.clock() - start) * 1000 / 3))
end
bench(1920, 1080, false)
bench(3840, 2160, false)
bench(1920, 1080, true)
bench(3840, 2160, true)
