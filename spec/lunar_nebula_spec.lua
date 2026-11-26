-- spec/lunar_nebula_spec.lua -- Lunar's nebulae (core.classes.Themes.lunar_space): structured
-- art, never brighter than the glow the contrast audit takes for them.

local space = require("core.classes.Themes.lunar_space")
local Background = require("core.ui.Background")

local function rgb(hex)
	return { tonumber(hex:sub(2, 3), 16), tonumber(hex:sub(4, 5), 16), tonumber(hex:sub(6, 7), 16) }
end
-- alpha of an ellipse's gradient at its normalised radius d (M.NEBULA_PROFILE, linear between)
local function profile(d)
	local P = space.NEBULA_PROFILE
	if d >= 1 then return 0 end
	for i = 1, #P - 1 do
		local a, b = P[i], P[i + 1]
		if d <= b[1] then return a[2] + (b[2] - a[2]) * (d - a[1]) / (b[1] - a[1]) end
	end
	return 0
end
-- the art over black at (x, y) of its box: its colour
local function art_at(blobs, x, y)
	local c = { 0, 0, 0 }
	for _, b in ipairs(blobs) do
		local t = math.rad(b[5])
		local dx, dy = x - b[1], y - b[2]
		local u = (dx * math.cos(t) + dy * math.sin(t)) / b[3]
		local v = (-dx * math.sin(t) + dy * math.cos(t)) / b[4]
		local a = profile(math.sqrt(u * u + v * v)) * b[7]
		if a > 0 then
			local k = rgb(b[6])
			for i = 1, 3 do c[i] = c[i] * (1 - a) + k[i] * a end
		end
	end
	return c
end
-- the audit's glow at normalised distance d from the box's centre (Background.extremes)
local function glow_alpha(g, d)
	local a, mid = g[2], g[3]
	if d >= 1 then return 0 end
	if d <= mid then return a + (a * 0.45 - a) * (d / mid) end
	return a * 0.45 * (1 - (d - mid) / (1 - mid))
end

describe("Lunar's nebulae", function()
	for name, n in pairs(space.NEBULA) do
		it(name .. " is gas, not a disc: hundreds of soft ellipses", function()
			local blobs = space.nebulaBlobs(n)
			assert.is_true(#blobs > 300)
			local _, count = space.SVG["nebula_" .. name]:gsub("<ellipse", "")
			assert.is_true(count > 250)
			-- none of them a glow filling the box
			for _, b in ipairs(blobs) do assert.is_true(b[3] < 256 * 0.85) end
		end)

		it(name .. " stays under its audit glow at every point", function()
			local blobs, W, H = space.nebulaBlobs(n)
			local g = space.GLOW["nebula_" .. name]
			local gc = rgb(g[1])
			local worst = 0
			for j = 0, 49 do
				for i = 0, 63 do
					local x, y = (i + 0.5) * W / 64, (j + 0.5) * H / 50
					local d = math.sqrt(((x - W / 2) / (W / 2)) ^ 2 + ((y - H / 2) / (H / 2)) ^ 2)
					local ga = glow_alpha(g, d)
					local bound = Background.luminance({ gc[1] * ga, gc[2] * ga, gc[3] * ga })
					local lum = Background.luminance(art_at(blobs, x, y))
					-- (past the glow's edge the art's last wisps stay under 3e-4, below one level of 255)
					assert.is_true(lum <= bound + 3e-4, ("%s at %.0f, %.0f: %.5f over %.5f"):format(name, x, y, lum, bound))
					if bound > 1e-4 then worst = math.max(worst, lum / bound) end
				end
			end
			assert.is_true(worst > 0.5, "and it is not far below it either: " .. worst)
		end)
	end
end)
