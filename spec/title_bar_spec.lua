local TitleBar = require("core.ui.TitleBar")
describe("core.ui.TitleBar layout", function()
	it("gives tabs the room previously reserved for search", function()
		assert.is_true(TitleBar.layout(1920, 138).groups > 1500)
	end)
	it("reserves native window buttons and a caption drag area", function()
		for width = 480, 1920, 40 do
			local lay = TitleBar.layout(width, 138, 5000)
			assert.is_true(lay.left <= width - 138 - 80)
		end
	end)
	it("keeps short tab lists at their natural width", function()
		assert.equal(200, TitleBar.layout(1920, 138, 200).groups)
	end)
	it("never returns negative space in a narrow window", function()
		assert.equal(0, TitleBar.layout(180, 138, 100).groups)
	end)
end)


describe("TitleBar image measurement", function()
	it("adds actual image width and configured spacing", function()
		local images = false
		local iup = {
			GetAttribute = function(w, key) return w[key] end,
			GetAttributeId = function(_, key) return key == "TABTITLE" and "Tools" or (images and "mark" or nil) end,
			GetHandle = function() return { WIDTH = "20" } end,
		}
		local bar = setmetatable({ _iup = iup, _root = {}, _groups = { TABSPADDING = "12x4", TABSIMAGESPACING = "7" } }, TitleBar)
		bar:_measureTabs({ {} }, {})
		local before = bar._tabs_width
		images = true
		bar:_measureTabs({ {} }, {})
		assert.equal(before + 27, bar._tabs_width)
	end)
end)
