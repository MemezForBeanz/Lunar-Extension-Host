describe("scroll content bounds", function()
	local function fixture(kind)
		local iup = require("core.lui.test").boot({})
		local Layout = require("core.imgui.Layout")
		local Element = require("core.imgui.Element")
		local content = iup.vbox{
			iup.canvas{RASTERSIZE="120x40"},
			iup.canvas{RASTERSIZE="120x900", VISIBLE="NO"},
			MARGIN="0x0", GAP="0",
		}
		local box = iup[kind]{content, EXPAND="YES", SCROLLBAR="VERTICAL", FLATSCROLLBAR="VERTICAL"}
		Layout.run(box, 200, 100)
		return iup, Element, Layout, box, content
	end
	for _, kind in ipairs{"scrollbox", "flatscrollbox"} do
		it(kind .. " excludes trailing hidden children from the scroll range", function()
			local iup, _, _, box = fixture(kind)
			assert.equal(40, tonumber(iup.GetAttribute(box, "YMAX")))
			assert.equal(100, tonumber(iup.GetAttribute(box, "DY")))
			assert.equal(0, tonumber(iup.GetAttribute(box, "POSY")))
		end)
		it(kind .. " restores overflow when the trailing content becomes visible", function()
			local iup, Element, Layout, box, content = fixture(kind)
			iup.SetAttribute(iup.GetChild(content, 1), "VISIBLE", "YES")
			Layout.run(box, 200, 100)
			assert.equal(940, tonumber(iup.GetAttribute(box, "YMAX")))
		end)
	end
end)

describe("terminal output following", function()
	it("follows new output on every transcript refresh, including process pumping", function()
		local Terminal = require("core.ui.Terminal")
		local calls = {}
		local terminal = setmetatable({
			_buffer = { snapshot = function() return "new output", {} end },
			_output = {
				setTranscript = function(_, text) calls[#calls + 1] = text end,
				scrollToEnd = function() calls[#calls + 1] = "end" end,
			},
		}, Terminal)
		terminal:_render()
		assert.same({"new output", "end"}, calls)
	end)
end)
