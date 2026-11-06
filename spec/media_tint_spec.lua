package.path = "./extensions/media/?.lua;" .. package.path
local tint = require("libs.tint")
local ffi = require("ffi")

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
end)
