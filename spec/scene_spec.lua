local Scene = require("core.lib.Scene")

local function fill(x)
	return { kind = "fill", x = x or 0, y = 0, w = 5, h = 5, color = 0x112233, alpha = 0.5 }
end

describe("Scene", function()
	it("validates the sprite and source contracts", function()
		local scene = { w = 8, h = 8, fill() }
		assert.is_true(Scene.validate(scene))
		scene[1].alpha = 1 / 0
		assert.is_nil(Scene.validate(scene))
		scene[1].alpha = 0.5
		scene[1].x = 0.2
		assert.is_nil(Scene.validate(scene))
		scene[1] = { kind = "image", snap = { w = 2, h = 2 }, x = -1, y = 0,
			sx = 1, sy = 0, sw = 2, sh = 2, alpha = 1 }
		assert.is_nil(Scene.validate(scene))
		scene[1].sw = 1
		assert.is_true(Scene.validate(scene))
		scene.regions = { { x = 0, y = 0, w = 8, h = 8, mode = "action" } }
		assert.is_nil(Scene.validate(scene))
		scene.regions[1].id = "close"
		assert.is_true(Scene.validate(scene))
	end)

	it("finds the topmost region including pass", function()
		local regions = {
			{ x = 0, y = 0, w = 5, h = 5, mode = "block" },
			{ x = 1, y = 1, w = 2, h = 2, mode = "action", id = "a" },
			{ x = 2, y = 2, w = 2, h = 2, mode = "pass" },
		}
		assert.equals("pass", Scene.hit(regions, 2, 2).mode)
		assert.equals("a", Scene.hit(regions, 1, 1).id)
		assert.equals("block", Scene.hit(regions, 0, 0).mode)
		assert.is_nil(Scene.hit(regions, 5, 5))
	end)

	it("flattens z then insertion order", function()
		local a, b, c = fill(1), fill(2), fill(3)
		local groups = {
			a = { z = 20, _order = 1, sprites = { a }, regions = {} },
			b = { z = 10, _order = 2, sprites = { b }, regions = {} },
			c = { z = 20, _order = 3, sprites = { c }, regions = {} },
		}
		local sprites = Scene.flatten(groups)
		assert.same({ b, a, c }, sprites)
	end)
end)
