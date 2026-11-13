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
		-- iFlatListKDown_CB is the element's K_DOWN callback, as iFlatListCreateMethod sets it;
		-- it moves only while the list has the focus
		Element.call(list, "K_DOWN")
		assert.is_nil(iup.GetAttribute(list, "VALUE"))
		c.event(list, st, {type = "focus"}, rt)
		Element.call(list, "K_DOWN") -- focus_pos starts at 0: the first Down selects item 1
		Element.call(list, "K_DOWN")
		Element.call(list, "K_DOWN")
		assert.are.equal("3", iup.GetAttribute(list, "VALUE"))
		assert.is_true((st.data.posy or 0) > 0)
	end)

	it("matches the fork marker width, highlight overlay, and focus feedback", function()
		local list = iup.flatlist{"a"}
		-- BORDER=NO: no WS_BORDER frame, so the client area starts at the control's corner
		iup.SetAttributes(list, "BORDER=NO,ITEMMARKERCOLOR=1 2 3,HLCOLOR=4 5 6,HLCOLORALPHA=128,FOCUSFEEDBACK=YES")
		local st = Element.state(list); st.x, st.y, st.w, st.h = 0, 0, 80, 20
		local cls = Classes.get("flatlist")
		cls.place(list, st, { font = require("core.imgui.Fonts").forElement, charsize = function() return 5, 10 end })
		iup.SetAttribute(list, "VALUE", "1")
		cls.event(list, st, { type = "focus" }, { redraw = function() end })
		local backend = Null.new()
		local dc = require("core.imgui.Draw").new(backend); dc:begin(100, 40)
		cls.draw(list, st, dc, {})
		backend:frame_end()
		local marker, overlay, focus
		for _, cmd in ipairs(backend:lastFrame()) do
			if cmd[1] == "rect_filled" and cmd[2] == 5 and cmd[3] == 5 then marker = cmd end
			if cmd[1] == "rect_filled" and cmd[2] == 0 and cmd[3] == 0 then overlay = cmd end
			-- iupdrvDrawFocusRect: a dotted rectangle, one pixel every other pixel
			if cmd[1] == "rect_filled" and cmd[2] == 2 and cmd[3] == 0 and cmd[4] == 3 and cmd[5] == 1 then focus = cmd end
		end
		assert.are.equal(3, marker[4] - marker[2])
		assert.is_truthy(overlay)
		assert.is_truthy(focus)
	end)
end)
