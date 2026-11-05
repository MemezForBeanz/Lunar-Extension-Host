local TitleBar = require("core.ui.TitleBar")

describe("core.ui.TitleBar", function()
	describe("layout", function()
		it("centres the field on the window at full width", function()
			local lay = TitleBar.layout(1920, 138)
			assert.equal(480, lay.field)
			assert.equal((1920 - 480) / 2, lay.left)
		end)

		it("narrows the field as the window narrows", function()
			assert.equal(360, TitleBar.layout(1100, 138).field)
			assert.equal(240, TitleBar.layout(720, 138).field)
		end)

		it("never lets the field reach the window buttons", function()
			for width = 480, 1920, 40 do
				local lay = TitleBar.layout(width, 138)
				assert.is_true(lay.left + lay.field <= width - (8 + 138) or lay.left <= 48,
					"field overlaps the right end at " .. width)
			end
		end)

		it("gives the groups whatever the left end has spare, and never less than nothing", function()
			assert.is_true(TitleBar.layout(1920, 138).groups > 400)
			assert.equal(0, TitleBar.layout(400, 138).groups)
		end)

		it("moves the field off centre rather than cut the groups", function()
			local centred = TitleBar.layout(1000, 138)
			local moved = TitleBar.layout(1000, 138, 400)
			assert.is_true(moved.left > centred.left)
			assert.equal(moved.field, centred.field)
		end)

		it("keeps the field centred without window buttons", function()
			local lay = TitleBar.layout(1100, 0)
			assert.equal((1100 - lay.field) / 2, lay.left)
		end)
	end)
end)
