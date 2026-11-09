local iup = require("core.imgui.iup")
local Element = require("core.imgui.Element")
local Classes = require("core.imgui.Classes")

describe("imgui scrollbox", function()
	local function layout(child, w, h)
		local box = iup.flatscrollbox{child, SCROLLBAR = "VERTICAL"}
		local st = Element.state(box); st.x, st.y, st.w, st.h = 0, 0, w, h
		local cs = Element.state(child)
		local L = { natural = function() return 40, 200 end, charsize = function() return 8, 16 end,
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
end)
