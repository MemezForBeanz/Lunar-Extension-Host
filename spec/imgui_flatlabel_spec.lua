local Null = require("core.imgui.backend.Null")
local Fonts = require("core.imgui.Fonts")
local Element = require("core.imgui.Element")
local iup = require("core.imgui.iup")
local Classes = require("core.imgui.Classes")

describe("imgui flatlabel", function()
	before_each(function()
		Fonts.backend = Null.new(); Fonts.reset()
		Element.globals.DEFAULTFONT = "Segoe UI, 10"
	end)
	it("includes image, text, spacing and padding in natural size", function()
		local label = iup.flatlabel{ TITLE = "Text", IMAGEPOSITION = "TOP", SPACING = 3, PADDING = "2x1" }
		local s = Element.state(label)
		local w, h = Classes.get("flatlabel").natural(label, s, {})
		assert.is_true(w >= 4)
		assert.is_true(h >= 13 + 2)
	end)
	it("handles hover callbacks without making labels focusable", function()
		local entered = 0
		local label = iup.flatlabel{ flat_enterwindow_cb = function() entered = entered + 1 end }
		local s, c = Element.state(label), Classes.get("flatlabel")
		c.event(label, s, { type = "enter" }, { redraw = function() end })
		assert.are.equal(1, entered)
		assert.is_nil(c.focusable)
	end)
	it("leaves the enclosing Carbon layer visible instead of painting a label patch", function()
		local F = require("core.imgui.widgets.flatdraw")
		local label = iup.flatlabel{ TITLE="Employee", CARBONSTYLE="YES" }
		local box = iup.vbox{label, BGCOLOR="244 244 244"}
		local dialog = iup.dialog{box, BGCOLOR="255 255 255"}
		local old_icon, old_box = F.icon, F.boxAttrib
		local backgrounds = {}
		F.icon = function() end
		F.boxAttrib = function(_, _, _, _, _, _, _, _, bg) backgrounds[#backgrounds+1] = bg end
		local ok, err = pcall(Classes.get("flatlabel").draw, label, Element.state(label), { fill=function(_,_,_,_,_,bg) backgrounds[#backgrounds+1]=bg end })
		F.icon, F.boxAttrib = old_icon, old_box
		assert.is_true(ok, err)
		assert.same({}, backgrounds)
		iup.Destroy(dialog)
	end)
end)
