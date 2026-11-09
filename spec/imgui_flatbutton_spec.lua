local Null = require("core.imgui.backend.Null")
local Fonts = require("core.imgui.Fonts")
local Element = require("core.imgui.Element")
local iup = require("core.imgui.iup")
local Classes = require("core.imgui.Classes")

describe("imgui flatbutton", function()
	local rt
	before_each(function()
		local b = Null.new(); Fonts.backend = b; Fonts.reset()
		Element.globals.DEFAULTFONT = "Segoe UI, 10"
		Element.globals.DLGBGCOLOR, Element.globals.DLGFGCOLOR = "240 240 240", "0 0 0"
		rt = { redraw = function() end, capture = function() end, release = function() end }
	end)
	it("measures padding and border", function()
		local b = iup.flatbutton{ TITLE = "OK", PADDING = "4x2", BORDERWIDTH = "2" }
		local s = Element.state(b)
		local w, h = Classes.get("flatbutton").natural(b, s, { })
		assert.is_true(w >= 4 + 2 * 4 + 2 * 2)
		assert.is_true(h >= 13 + 2 * 2 + 2 * 2)
	end)
	it("fires action only for a release inside after an inside press", function()
		local count = 0
		local b = iup.flatbutton{ TITLE = "Run", flat_action = function() count = count + 1 end }
		local s, c = Element.state(b), Classes.get("flatbutton")
		s.w, s.h = 80, 24
		c.event(b, s, { type = "press", button = 1, lx = 4, ly = 4 }, rt)
		c.event(b, s, { type = "release", button = 1, lx = 4, ly = 4 }, rt)
		assert.are.equal(1, count)
		c.event(b, s, { type = "press", button = 1, lx = 4, ly = 4 }, rt)
		c.event(b, s, { type = "release", button = 1, lx = 90, ly = 4 }, rt)
		assert.are.equal(1, count)
	end)
	it("toggles and activates from keyboard", function()
		local changed = 0
		local b = iup.flatbutton{ TOGGLE = "YES", VALUECHANGED_CB = function() changed = changed + 1 end }
		local s, c = Element.state(b), Classes.get("flatbutton")
		s.w, s.h = 40, 20
		c.event(b, s, { type = "key", key = iup.K_SP }, rt)
		assert.are.equal("ON", b.VALUE) -- iFlatButtonGetValueAttrib returns ON/OFF
		assert.are.equal(1, changed)
	end)
end)
