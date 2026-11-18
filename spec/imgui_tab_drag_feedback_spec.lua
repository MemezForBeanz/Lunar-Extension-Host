local Null = require("core.imgui.backend.Null")
local R = require("core.imgui.Runtime")
local Element = require("core.imgui.Element")
local iup = require("core.imgui.iup")
local TabOrder = require("core.classes.TabOrder")
local TabDragMotion = require("core.ui.TabDragMotion")
local Compositor = require("core.lib.Compositor")
local native = require("core.imgui.native.compositor")

describe("ImGui tab drag feedback", function()
	it("shows combine and insertion cues through the real widget callbacks", function()
		local B = Null.new()
		R.init(B)
		local a, b = iup.vbox{}, iup.vbox{}
		local tabs = iup.flattabs{ a, b, TABTITLE0 = "First tab", TABTITLE1 = "Second tab" }
		local dialog = iup.dialog{ tabs, RASTERSIZE = "600x300" }
		iup.Show(dialog)
		R.frame()
		local comp = Compositor.new(assert(native.overlay(dialog)))
		local director = {
			enabled = function() return true end,
			animate = function(_, s) s.on_frame(s.to) end,
			cancel = function() end,
			atFrameEnd = function(_, f) f() end,
		}
		local feedback = TabDragMotion:new{ iup = iup, director = director, compositor = function() return comp end }
		local order = TabOrder:new{ iup = iup, motion = feedback }
		order:setGroups({ stripsDeepestFirst = function() return { tabs } end, isGroupStrip = function() return false end })
		order:install(tabs)
		local st = Element.state(tabs)
		st.x, st.y, st.w, st.h = 20, 30, 600, 300
		local second
		for x = 0, st.w - 1 do if iup.ConvertXYToPos(tabs, x, 8) == 1 then second = x; break end end
		assert.is_number(second)
		R.deliver(tabs, { type = "press", button = 1, x = st.x + 10, y = st.y + 8 })
		R.deliver(tabs, { type = "move", x = st.x + second + 20, y = st.y + 8 })
		assert.is_not_nil(feedback._state)
		assert.equal("combine", feedback._state.kind)
		assert.is_true(#comp.groups["tab-drag"].sprites > 0)
		R.deliver(tabs, { type = "move", x = st.x + second + 1, y = st.y + 8 })
		assert.equal("caret", feedback._state.kind)
		iup.Destroy(dialog)
	end)
end)
