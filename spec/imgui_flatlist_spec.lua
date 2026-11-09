local iup = require("core.imgui.iup")
local Element = require("core.imgui.Element")
local Classes = require("core.imgui.Classes")
local Null = require("core.imgui.backend.Null")
local Fonts = require("core.imgui.Fonts")
Fonts.backend = Null.new(); Fonts.reset()

describe("imgui flatlist", function()
	it("keeps indexed items and supports mutation attributes", function()
		local list = iup.flatlist{"a", "b"}
		assert.are.equal("2", iup.GetAttribute(list, "COUNT"))
		iup.SetAttribute(list, "APPENDITEM", "c")
		assert.are.equal("3", iup.GetAttribute(list, "COUNT"))
		iup.SetAttribute(list, "INSERTITEM2", "x")
		assert.are.equal("x", iup.GetAttribute(list, "2"))
		iup.SetAttribute(list, "REMOVEITEM", "2")
		assert.are.equal("b", iup.GetAttribute(list, "2"))
	end)

	it("fires selection callbacks and maintains multiple values", function()
		local seen = {}
		local list = iup.flatlist{"a", "b", "c"}
		list.flat_action = function(_, text, item, state) seen[#seen + 1] = {text, item, state} end
		list.valuechanged_cb = function() seen.changed = true end
		local st = Element.state(list); st.x, st.y, st.w, st.h = 0, 0, 100, 60
		local rt = { redraw = function() end }
		Classes.get("flatlist").event(list, st, {type = "press", button = 1, lx = 2, ly = 25}, rt)
		assert.are.equal("b", seen[1][1])
		assert.are.equal("2", iup.GetAttribute(list, "VALUE"))
		assert.is_true(seen.changed)
		iup.SetAttribute(list, "MULTIPLE", "YES")
		Classes.get("flatlist").event(list, st, {type = "press", button = 1, lx = 2, ly = 2, mods = {}}, rt)
		assert.are.equal("+--", iup.GetAttribute(list, "VALUE"))
	end)

	it("moves keyboard focus and scrolls the focused row into view", function()
		local list = iup.flatlist{"a", "b", "c", "d", "e"}
		local st = Element.state(list); st.w, st.h = 80, 20
		local rt = { redraw = function() end }
		local c = Classes.get("flatlist")
		c.place(list, st, { font = require("core.imgui.Fonts").forElement, charsize = function() return 5, 10 end, natural = function() return 0, 0 end })
		c.event(list, st, {type = "key", key = iup.K_DOWN}, rt)
		c.event(list, st, {type = "key", key = iup.K_DOWN}, rt)
		assert.are.equal("3", iup.GetAttribute(list, "VALUE"))
		assert.is_true((st.data.posy or 0) > 0)
	end)
end)
