local iup = require("core.imgui.iup")
local Element = require("core.imgui.Element")
local Classes = require("core.imgui.Classes")

describe("imgui scrollbox", function()
	local function layout(child, w, h)
		local box = iup.flatscrollbox{child, SCROLLBAR = "VERTICAL"}
		local st = Element.state(box); st.x, st.y, st.w, st.h = 0, 0, w, h
		local cs = Element.state(child)
		local L = { currentSize = function(_, cw, ch) return cw, ch end, natural = function() return 40, 200 end, charsize = function() return 8, 16 end,
			place = function(_, x, y, pw, ph) cs.x, cs.y, cs.w, cs.h = x, y, pw, ph end }
		Classes.get("flatscrollbox").natural(box, st, L)
		Classes.get("flatscrollbox").place(box, st, L)
		return box, st, cs
	end

	it("computes a virtual range and places the child opposite POSY", function()
		local box, st, cs = layout(iup.fill{}, 100, 50)
		assert.are.equal("200", iup.GetAttribute(box, "YMAX"))
		assert.are.equal("50", iup.GetAttribute(box, "DY"))
		iup.SetAttribute(box, "POSY", "20")
		assert.are.equal(-20, cs.y)
	end)

	it("supports TOP, BOTTOM and wheel scrolling", function()
		local box, st = layout(iup.fill{}, 100, 50)
		iup.SetAttribute(box, "SCROLLTO", "BOTTOM")
		assert.are.equal("150", iup.GetAttribute(box, "POSY"))
		local consumed = Classes.get("flatscrollbox").event(box, st, {type = "wheel", dy = 1}, {})
		assert.is_true(consumed)
		assert.are.equal("126", iup.GetAttribute(box, "POSY"))
	end)

	it("FITCONTENT uses the child's minimum content rather than the viewport", function()
		local child = iup.hbox{iup.canvas{RASTERSIZE = "200x20"}, iup.canvas{RASTERSIZE = "200x20"}}
		local box = iup.flatscrollbox{child, FITCONTENT = "YES", SCROLLBAR = "BOTH"}
		local st = Element.state(box); st.x, st.y, st.w, st.h = 0, 0, 100, 50
		local cs = Element.state(child)
		local L = { currentSize = function(_, cw, ch) return cw, ch end,
			natural = function(c) return c == child and 400 or 200, 20 end,
			minContent = function(c, horizontal) return c == child and (horizontal and 240 or 20) or 0 end,
			place = function(_, x, y, w, h) cs.x, cs.y, cs.w, cs.h = x, y, w, h end,
			charsize = function() return 8, 16 end,
		}
		Classes.get("flatscrollbox").natural(box, st, L)
		Classes.get("flatscrollbox").place(box, st, L)
		assert.are.equal("240", iup.GetAttribute(box, "XMAX"))
		assert.are.equal(240, cs.w)
	end)
end)
