local Null = require("core.imgui.backend.Null")
local Fonts = require("core.imgui.Fonts")
local Element = require("core.imgui.Element")
local iup = require("core.imgui.iup")
local Classes = require("core.imgui.Classes")

describe("imgui flatlabel", function()
	before_each(function()
		Fonts.backend = Null.new(); Fonts.reset()
		Element.globals.DEFAULTFONT = "Segoe UI, 10"
	end)
	it("includes image, text, spacing and padding in natural size", function()
		local label = iup.flatlabel{ TITLE = "Text", IMAGEPOSITION = "TOP", SPACING = 3, PADDING = "2x1" }
		local s = Element.state(label)
		local w, h = Classes.get("flatlabel").natural(label, s, {})
		assert.is_true(w >= 4)
		assert.is_true(h >= 13 + 2)
	end)
	it("handles hover callbacks without making labels focusable", function()
		local entered = 0
		local label = iup.flatlabel{ flat_enterwindow_cb = function() entered = entered + 1 end }
		local s, c = Element.state(label), Classes.get("flatlabel")
		c.event(label, s, { type = "enter" }, { redraw = function() end })
		assert.are.equal(1, entered)
		assert.is_nil(c.focusable)
	end)
end)
