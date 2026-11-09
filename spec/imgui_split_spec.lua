local iup = require("core.imgui.iup")
local Element = require("core.imgui.Element")
local Classes = require("core.imgui.Classes")

describe("imgui split", function()
	it("places two children at VALUE and exposes ORIENTATION", function()
		local a, b = iup.fill{}, iup.fill{}
		local split = iup.split{a, b, VALUE = "250", BARSIZE = "4"}
		local st = Element.state(split); st.x, st.y, st.w, st.h = 0, 0, 104, 20
		local as, bs = Element.state(a), Element.state(b)
		Classes.get("split").place(split, st, { natural = function() return 10, 10 end,
			place = function(_, x, y, w, h) local s = Element.state(_); s.x, s.y, s.w, s.h = x, y, w, h end })
		assert.are.equal("VERTICAL", iup.GetAttribute(split, "ORIENTATION"))
		assert.are.equal(25, as.w)
		assert.are.equal(75, bs.w)
	end)

	it("drags the sash and reports VALUECHANGED_CB", function()
		local split = iup.split{iup.fill{}, iup.fill{}, BARSIZE = "4"}
		local st = Element.state(split); st.w, st.h = 104, 20; st.data.first, st.data.total = 50, 100
		local changed = false
		split.valuechanged_cb = function() changed = true end
		local captured = false
		local rt = { capture = function() captured = true end, release = function() end, relayout = function() end }
		local c = Classes.get("split")
		c.event(split, st, {type = "press", button = 1, lx = 51, ly = 1, x = 51, y = 1}, rt)
		c.event(split, st, {type = "move", x = 61, y = 1, lx = 61, ly = 1}, rt)
		assert.is_true(captured)
		assert.is_true(changed)
		assert.are.equal("600", iup.GetAttribute(split, "VALUE"))
	end)
end)
