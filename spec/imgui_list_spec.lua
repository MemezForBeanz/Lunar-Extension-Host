local iup = require("core.imgui.iup")
local Element = require("core.imgui.Element")
local Classes = require("core.imgui.Classes")
local Null = require("core.imgui.backend.Null")
local Fonts = require("core.imgui.Fonts")
Fonts.backend = Null.new(); Fonts.reset()

describe("imgui list", function()
	it("fires native ACTION arguments", function()
		local got
		local list = iup.list{"one", "two"}
		list.action = function(_, text, item, state) got = {text, item, state} end
		local st = Element.state(list); st.w, st.h = 100, 40
		Classes.get("list").event(list, st, {type = "press", button = 1, lx = 1, ly = 20}, { redraw = function() end })
		assert.are.same({"two", 2, 1}, got)
	end)

	it("opens a dropdown overlay", function()
		local opened
		local list = iup.list{"one", "two", DROPDOWN = "YES"}
		local st = Element.state(list); st.w, st.h = 100, 20
		local rt = { overlay = function(o) opened = o; return { close = function() end } end }
		Classes.get("list").event(list, st, {type = "press", button = 1}, rt)
		assert.is_true(st.data.open)
		assert.is_not_nil(opened)
	end)
end)
