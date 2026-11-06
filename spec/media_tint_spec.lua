package.path = "./extensions/media/?.lua;" .. package.path
local tint = require("libs.tint")
local ffi = require("ffi")
local contrast = require("core.classes.Themes.lunar_rules").contrast

local function lightness(c)
	local high, low = math.max(c[1], c[2], c[3]), math.min(c[1], c[2], c[3])
	return (high + low) / 2 / 255
end

describe("art tint", function()
	it("always gives a dark surface, so white text stays readable", function()
		for _, colour in ipairs({ { 255, 255, 0 }, { 250, 240, 230 }, { 3, 2, 1 }, { 0, 200, 255 } }) do
			assert.is_true(lightness(tint.surface(colour[1], colour[2], colour[3])) < 0.2)
		end
	end)

	it("keeps the hue of the art", function()
		local red = tint.surface(220, 30, 30)
		assert.is_true(red[1] > red[3])
		local blue = tint.surface(30, 30, 220)
		assert.is_true(blue[3] > blue[1])
	end)

	it("falls back for grey art", function()
		assert.same(tint.FALLBACK, tint.surface(128, 128, 128))
	end)

	it("reads a picture, ignoring black", function()
		local w, h = 16, 16
		local pixels = ffi.new("uint8_t[?]", w * h * 4)
		for i = 0, w * h - 1 do
			if i % 2 == 0 then
				pixels[i * 4], pixels[i * 4 + 1], pixels[i * 4 + 2] = 20, 180, 40   -- BGR: green
			end
		end
		local colour = tint.ofPixels(pixels, w * 4, w, h)
		assert.is_true(colour[2] > colour[1] and colour[2] > colour[3])
	end)

	it("gives untitled and titled art a stable colour", function()
		assert.same(tint.ofTitle("Marrow"), tint.ofTitle("Marrow"))
		assert.equal(3, #tint.ofTitle(nil))
	end)

	it("writes a colour the way IUP reads it", function()
		assert.equal("1 2 3", tint.attr({ 1, 2, 3 }))
	end)

	it("gives a light page a pale surface of the same hue", function()
		local red = tint.surface(220, 30, 30, true)
		assert.is_true(lightness(red) > 0.85)
		assert.is_true(red[1] > red[3])
		assert.same(tint.LIGHT_FALLBACK, tint.surface(128, 128, 128, true))
		assert.is_true(lightness(tint.ofTitle("Marrow", true)) > 0.85)
	end)

	it("tells a light page from a dark one", function()
		assert.is_true(tint.isLight("242 242 247"))
		assert.is_false(tint.isLight("30 32 40"))
		assert.is_false(tint.isLight(nil))
	end)

	it("reports a picture with no colour in it", function()
		local pixels = ffi.new("uint8_t[?]", 16 * 16 * 4)
		assert.is_nil(tint.average(pixels, 16 * 4, 16, 16))
		assert.same(tint.FALLBACK, tint.ofPixels(pixels, 16 * 4, 16, 16))
		assert.same(tint.LIGHT_FALLBACK, tint.ofPixels(pixels, 16 * 4, 16, 16, true))
	end)

	describe("what sits on a surface", function()
		-- Every hue, at the extremes of saturation art can bring.
		local function each_surface(light, check)
			for hue = 0, 345, 15 do
				local angle = hue / 60
				local x = 1 - math.abs(angle % 2 - 1)
				local sector = math.floor(angle)
				local r = (sector == 0 or sector == 5) and 1 or (sector == 1 or sector == 4) and x or 0
				local g = (sector == 1 or sector == 2) and 1 or (sector == 0 or sector == 3) and x or 0
				local b = (sector == 3 or sector == 4) and 1 or (sector == 2 or sector == 5) and x or 0
				for _, spread in ipairs({ 1, 0.2 }) do
					local base = 255 * (1 - spread)
					check(tint.scheme(tint.surface(base + r * 255 * spread, base + g * 255 * spread,
						base + b * 255 * spread, light), light))
				end
			end
			check(tint.scheme(tint.surface(128, 128, 128, light), light))
		end

		for _, light in ipairs({ false, true }) do
			local name = light and "pale" or "dark"

			it("keeps text readable on a " .. name .. " surface", function()
				each_surface(light, function(scheme)
					assert.is_true(contrast(scheme.text, scheme.surface) >= 7, scheme.surface)
					assert.is_true(contrast(scheme.muted, scheme.surface) >= 4.5, scheme.surface)
				end)
			end)

			it("keeps text readable on a quieter control on a " .. name .. " surface", function()
				each_surface(light, function(scheme)
					assert.is_true(contrast(scheme.text, scheme.lift) >= 4.5, scheme.lift)
				end)
			end)
		end

		it("keeps a seek track visible on a pale surface", function()
			each_surface(true, function(scheme)
				assert.is_true(contrast(scheme.track, scheme.surface) >= 2, scheme.track)
			end)
		end)
	end)
end)
