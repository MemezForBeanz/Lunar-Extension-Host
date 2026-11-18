-- A toolbar field is as tall as the dropdowns and buttons beside it, in every theme.
describe("core.ui.FlatField height", function()
	local Reactor = require("core.ui.ThemeReactor")
	local old
	before_each(function() old = Reactor.themeManager end)
	after_each(function() Reactor.themeManager = old end)

	local function theme(rules)
		local t = { rules = function() return rules end }
		return { activeTheme = function() return t end }
	end

	local function field_height(iup)
		local Layout = require("core.imgui.Layout")
		local Element = require("core.imgui.Element")
		local FlatField = require("core.ui.FlatField")
		local field = FlatField.new(iup, { cue = "Search" })
		local button = iup.flatbutton{ TITLE = "Browse" }
		local row = iup.hbox{ field.widget, button, ALIGNMENT = "ACENTER" }
		Layout.run(row, 600, 200)
		return Element.state(field.widget).h, field
	end

	it("matches a theme's 32 px controls", function()
		local iup = require("core.lui.test").boot({})
		Reactor.themeManager = function() return theme({ dropbutton = { controlheight = 32 }, text = { controlheight = 32 } }) end
		local h = field_height(iup)
		assert.equal(32, h)
	end)

	it("matches Carbon's 40 px fields and follows a theme switch", function()
		local iup = require("core.lui.test").boot({})
		Reactor.themeManager = function() return theme({ dropbutton = { controlheight = 40 } }) end
		local h, field = field_height(iup)
		assert.equal(40, h)
		Reactor.themeManager = function() return theme({}) end
		field:_onThemeApply()
		assert.equal(require("core.lib.CarbonLayout").PAGE.control - 2, tonumber(iup.GetAttribute(field.text, "MAXSIZE"):match("x(%d+)")))
	end)
end)
