local Null = require("core.imgui.backend.Null")
local Fonts = require("core.imgui.Fonts")
local Element = require("core.imgui.Element")
local iup = require("core.imgui.iup")
local Classes = require("core.imgui.Classes")

describe("imgui flatframe", function()
	before_each(function()
		Fonts.backend = Null.new(); Fonts.reset()
		Element.globals.DEFAULTFONT = "Segoe UI, 10"
	end)
	it("adds title and frame decoration to child natural size", function()
		local child = iup.flatlabel{ TITLE = "body" }
		local frame = iup.flatframe{ child, TITLE = "Section", FRAMEWIDTH = "2", FRAMESPACE = "3" }
		local s = Element.state(frame)
		local L = { natural = function(e) return Classes.get(Element.state(e).classname).natural(e, Element.state(e), {}) end }
		local w, h = Classes.get("flatframe").natural(frame, s, L)
		assert.is_true(w > 0 and h > 0)
	end)
	it("places its one child inside the title and frame", function()
		local child, frame = iup.flatlabel{ TITLE = "body" }, nil
		frame = iup.flatframe{ child, TITLE = "Section" }
		local s, cs, c = Element.state(frame), Element.state(child), Classes.get("flatframe")
		s.x, s.y, s.w, s.h = 0, 0, 120, 80
		c.place(frame, s, { place = function(_, x, y, w, h) cs.x, cs.y, cs.w, cs.h = x, y, w, h end })
		assert.is_true(cs.y > 0 and cs.w < s.w)
	end)
end)
