local Null = require("core.imgui.backend.Null")
local Fonts = require("core.imgui.Fonts")
local Element = require("core.imgui.Element")
local Draw = require("core.imgui.Draw")
local iup = require("core.imgui.iup")
local Classes = require("core.imgui.Classes")

-- Keyboard focus is a rounded ring in the control's own shape (buttons and tabs).
describe("imgui focus rings", function()
	local B
	before_each(function()
		B = Null.new(); Fonts.backend = B; Fonts.reset()
		Element.globals.DEFAULTFONT = "Segoe UI, 10"
		Element.globals.DLGBGCOLOR, Element.globals.DLGFGCOLOR = "240 240 240", "0 0 0"
	end)
	local function rings(draw)
		local dc = Draw.new(B)
		B.frame_begin(); dc:begin(400, 200)
		draw(dc)
		B.frame_end()
		local out = {}
		for _, c in ipairs(B.lastFrame()) do
			if c[1] == "rect" and c[8] == 2 then out[#out + 1] = c end
		end
		return out
	end
	it("rounds a themed button's ring to its corners", function()
		local b = iup.flatbutton{ TITLE = "OK", CANFOCUS = "YES", FOCUSFEEDBACK = "YES", FOCUSCOLOR = "255 0 0", CORNERRADIUS = "8" }
		local s, c = Element.state(b), Classes.get("flatbutton")
		s.x, s.y, s.w, s.h = 10, 10, 80, 32
		s.data.has_focus = true
		local found = rings(function(dc) c.draw(b, s, dc) end)
		assert.equal(1, #found)
		assert.equal(6, found[1][7])
	end)
	it("rings the current tab while the strip has focus, and not otherwise", function()
		local tabs = iup.flattabs{ iup.vbox{ TABTITLE = "One" }, iup.vbox{ TABTITLE = "Two" },
			FOCUSCOLOR = "255 0 0", CORNERRADIUS = "6" }
		local s, c = Element.state(tabs), Classes.get("flattabs")
		s.x, s.y, s.w, s.h = 0, 0, 300, 120
		local R = require("core.imgui.Runtime")
		local real = R.focused
		R.focused = function() return tabs end
		local ok, found = pcall(rings, function(dc) c.draw(tabs, s, dc) end)
		R.focused = function() return nil end
		local ok2, none = pcall(rings, function(dc) c.draw(tabs, s, dc) end)
		R.focused = real
		assert.is_true(ok, tostring(found)); assert.is_true(ok2, tostring(none))
		assert.equal(1, #found)
		assert.equal(5, found[1][7])
		assert.equal(0, #none)
	end)
end)
