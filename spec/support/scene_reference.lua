-- Independent, deliberately direct renderer for the compositor golden check.
-- Each source pixel is composited into four numeric channel arrays; geometry
-- and coverage are computed from the scene description, not native structs.
local M = {}

local function mul(a, b)
	local t = a * b + 128
	return math.floor((t + math.floor(t / 256)) / 256)
end

local function coverage(s, x, y)
	-- Clamped to half the short side, and to 1<<20 (BLEND_MAX_RADIUS in blend.h).
	local r = math.min(s.radius, math.floor(math.min(s.w, s.h) / 2), 1048576)
	if r == 0 then return 255 end
	local inside = 0
	for row = 0, 3 do
		for col = 0, 3 do
			local xx, yy = x + (col + 0.5) / 4, y + (row + 0.5) / 4
			local cx = xx < s.x + r and s.x + r or (xx > s.x + s.w - r and s.x + s.w - r or xx)
			local cy = yy < s.y + r and s.y + r or (yy > s.y + s.h - r and s.y + s.h - r or yy)
			if (xx - cx) ^ 2 + (yy - cy) ^ 2 <= r ^ 2 then inside = inside + 1 end
		end
	end
	return math.floor((inside * 255 + 8) / 16)
end

function M.render(scene)
	local pixels = {}
	for i = 1, scene.w * scene.h * 4 do pixels[i] = 0 end
	for _, s in ipairs(scene) do
		local sx, sy = s.sx or 0, s.sy or 0
		local sw = s.kind == "image" and (s.sw or s.snap.w - sx) or s.w
		local sh = s.kind == "image" and (s.sh or s.snap.h - sy) or s.h
		local alpha = math.floor(s.alpha * 255 + 0.5)
		local cr = math.floor(s.color and s.color / 65536 or 0) % 256
		local cg = math.floor(s.color and s.color / 256 or 0) % 256
		local cb = (s.color or 0) % 256
		for y = 0, scene.h - 1 do
			for x = 0, scene.w - 1 do
				if x >= s.x and x < s.x + sw and y >= s.y and y < s.y + sh and
					(not s.clip or (x >= s.clip.x and x < s.clip.x + s.clip.w and
					y >= s.clip.y and y < s.clip.y + s.clip.h)) then
					local b, g, r, a
					if s.kind == "image" then
						local offset = ((sy + y - s.y) * s.snap.w + sx + x - s.x) * 4 + 1
						b, g, r, a = s.snap.bytes:byte(offset, offset + 3)
						b, g, r, a = mul(b, alpha), mul(g, alpha), mul(r, alpha), mul(a, alpha)
					else
						local paint = true
						if s.kind == "stroke" then
							local t = s.thickness
							paint = y < s.y + t or y >= s.y + sh - t or
								x < s.x + t or x >= s.x + sw - t
						end
						if paint then
							local c = s.kind == "rrect" and coverage(s, x, y) or 255
							b, g, r, a = mul(mul(cb, alpha), c), mul(mul(cg, alpha), c),
								mul(mul(cr, alpha), c), mul(alpha, c)
						end
					end
					if a and a > 0 then
						local pos = (y * scene.w + x) * 4 + 1
						local inv = 255 - a
						pixels[pos] = b + mul(pixels[pos], inv)
						pixels[pos + 1] = g + mul(pixels[pos + 1], inv)
						pixels[pos + 2] = r + mul(pixels[pos + 2], inv)
						pixels[pos + 3] = a + mul(pixels[pos + 3], inv)
					end
				end
			end
		end
	end
	local chunks = {}
	for i = 1, #pixels, 4 do
		chunks[#chunks + 1] = string.char(pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3])
	end
	return table.concat(chunks)
end

return M
