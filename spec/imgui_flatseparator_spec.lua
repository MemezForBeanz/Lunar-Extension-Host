local Null = require("core.imgui.backend.Null")
local Fonts = require("core.imgui.Fonts")
local Element = require("core.imgui.Element")
local iup = require("core.imgui.iup")
local Classes = require("core.imgui.Classes")
local Draw = require("core.imgui.Draw")

describe("imgui flatseparator", function()
	before_each(function()
		Fonts.backend = Null.new(); Fonts.reset()
	end)
	it("uses barsize on its non-expanding axis", function()
		local sep = iup.flatseparator{ ORIENTATION = "HORIZONTAL", BARSIZE = "7" }
		local w, h = Classes.get("flatseparator").natural(sep, Element.state(sep))
		assert.are.same({ 0, 7 }, { w, h })
	end)
	it("draws a hot sash and reports drag callbacks", function()
		local pressed = 0
		local sep = iup.flatseparator{ STYLE = "SASH", flat_button_cb = function() pressed = pressed + 1 end }
		local s, c = Element.state(sep), Classes.get("flatseparator")
		s.x, s.y, s.w, s.h = 0, 0, 5, 40
		local b, dc = Null.new(), nil
		dc = Draw.new(b); dc:begin(100, 100)
		c.event(sep, s, { type = "enter" }, { redraw = function() end })
		c.draw(sep, s, dc)
		assert.is_true(#b.frame_calls > 0)
		c.event(sep, s, { type = "press", button = 1, lx = 2, ly = 3 }, { capture = function() end })
		assert.are.equal(1, pressed)
	end)
end)
