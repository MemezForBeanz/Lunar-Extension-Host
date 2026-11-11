-- Styling ownership between core.lui and the ThemeManager: a widget with a role belongs to
-- the theme; explicit colours on a widget without one belong to the component, and the
-- ThemeManager neither overwrites them nor records them as the widget's original look.
local T = require("core.lui.test")
local ui = require("core.lui")
local ThemeManager = require("core.classes.ThemeManager")
local TR = require("core.ui.ThemeReactor")

local iup, Element
before_each(function() iup, _, _, Element = T.boot({}) end)

-- The ThemeManager's per-widget step, on a bare instance (no native batch helper), with a
-- rule that themes background, text colour and padding.
local function manager()
	local saved = {}
	local mgr = setmetatable({ _iup = iup, _orig = {}, _theme_font = nil }, { __index = ThemeManager })
	mgr._attrsFromRule = function() return { BGCOLOR = "1 1 1", FGCOLOR = "2 2 2", PADDING = "3x3" } end
	mgr._save = function(_, ih, attr) saved[#saved + 1] = attr end
	return mgr, saved
end

describe("lui styling ownership", function()
	it("claims explicit colours on a widget without a role; the theme leaves them alone", function()
		local root = ui.mount(ui.Text{ "x", bg = "9 9 9" }, { iup = iup })
		local h = root:widget()
		assert.same({ BGCOLOR = true }, TR.claimed(h))
		local mgr, saved = manager()
		mgr:_applyElement(h, { flatlabel = {} }, "flatlabel", nil, nil)
		assert.equal("9 9 9", Element.own(h, "BGCOLOR"), "not overwritten")
		assert.equal("2 2 2", Element.own(h, "FGCOLOR"), "the rest of the rule applies")
		table.sort(saved)
		assert.same({ "FGCOLOR", "PADDING" }, saved, "no original captured for the claimed colour")
	end)

	it("leaves a widget with a role to the theme, literal colours included", function()
		local root = ui.mount(ui.Text{ "x", role = "statusbar_text", fg = "60 60 60" }, { iup = iup })
		local h = root:widget()
		assert.is_nil(TR.claimed(h))
		local mgr = manager()
		mgr:_applyElement(h, { statusbar_text = {} }, "flatlabel", "statusbar_text", nil)
		assert.equal("2 2 2", Element.own(h, "FGCOLOR"), "the theme restyled the fallback colour")
	end)

	it("releases the claim when the colour prop goes away", function()
		local root = ui.mount(ui.Text{ "x", fg = "5 5 5" }, { iup = iup })
		local h = root:widget()
		assert.same({ FGCOLOR = true }, TR.claimed(h))
		root:update(ui.Text{ "x" })
		assert.is_nil(TR.claimed(h))
	end)
end)
