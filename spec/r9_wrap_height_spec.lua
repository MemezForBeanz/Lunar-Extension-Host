-- Round 9: a wrapping label's natural height follows the width it is laid out at.
local Null = require("core.imgui.backend.Null")
local Fonts = require("core.imgui.Fonts")
local Element = require("core.imgui.Element")
local Layout = require("core.imgui.Layout")
local iup = require("core.imgui.iup")

describe("wrapped label height for width", function()
	local TEXT = "A railway engineer crosses enemy lines to recover his locomotive, then races home."
	before_each(function()
		Fonts.backend = Null.new(); Fonts.reset()
		Element.globals.DEFAULTFONT = "Segoe UI, 10"
	end)
	local function line_height(label)
		local _, h = Fonts.forElement(label):charsize()
		return h
	end
	local function fixture(attrs)
		attrs = attrs or {}
		attrs.TITLE, attrs.TEXTWRAP, attrs.EXPAND = attrs.TITLE or TEXT, "YES", "HORIZONTAL"
		local label = iup.flatlabel(attrs)
		local after = iup.canvas{ RASTERSIZE = "10x10" }
		-- SHRINK: the label may get less than its unwrapped width, as in a narrow window
		local box = iup.vbox{ label, after, MARGIN = "0x0", GAP = "0", SHRINK = "YES" }
		return label, after, box
	end

	it("is one line where the text fits", function()
		local label, _, box = fixture()
		Layout.run(box, 4000, 600)
		assert.equal(line_height(label), Element.state(label).h)
	end)

	it("is as many lines as the text wraps into at a narrow width, in the same layout", function()
		local label, after, box = fixture()
		Layout.run(box, 120, 600)
		local st = Element.state(label)
		local lines = #require("core.imgui.Draw").wrap(Fonts.forElement(label), TEXT, 120)
		assert.is_true(lines > 1)
		assert.equal(lines * line_height(label), st.h)
		-- what follows sits right under the last line, not under a guessed height
		assert.equal(st.y + st.h, Element.state(after).y)
	end)

	it("shrinks again when the width grows", function()
		local label, _, box = fixture()
		Layout.run(box, 120, 600)
		Layout.run(box, 4000, 600)
		assert.equal(line_height(label), Element.state(label).h)
	end)

	it("keeps a height the page set itself", function()
		local label, _, box = fixture({ RASTERSIZE = "x135" })
		Layout.run(box, 120, 600)
		assert.equal(135, Element.state(label).h)
	end)

	it("follows a new title at the same width", function()
		local label, _, box = fixture({ TITLE = "Short" })
		Layout.run(box, 120, 600)
		assert.equal(line_height(label), Element.state(label).h)
		iup.SetAttribute(label, "TITLE", TEXT)
		Layout.run(box, 120, 600)
		assert.is_true(Element.state(label).h > line_height(label))
	end)
end)
