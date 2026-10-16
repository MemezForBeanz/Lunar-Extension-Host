-- spec/theme_type_scale_spec.lua — the Carbon type scale actually reaches widgets.
--
-- `ThemeManager` skips the per-widget FONT write for widgets that have no FONT of
-- their own, on the reasoning that they inherit `DEFAULTFONT` and `_applyGlobalFont`
-- has already set that to the theme's font. That is a real and worthwhile
-- optimisation -- a per-widget `IupSetStrAttribute("FONT", ...)` forces a synchronous
-- natural-size re-measure, and it was the single largest cost of a theme switch.
--
-- But it is only sound when the rule's font is the same font `DEFAULTFONT` is being
-- set to. Every entry in the Carbon type scale is deliberately NOT: a `heading-04`
-- is 21pt where the body is 11pt, and inheritance cannot deliver that.
--
-- Skipping those writes made the entire type scale inert -- headings are built as
-- flatlabels carrying a THEMEROLE and no FONT (see `core.lib.CarbonLayout.pageTitle`),
-- so every heading in the app rendered at body size and weight while the scale
-- looked correct in the theme source. This pins the distinction.

local ThemeManager = require("core.classes.ThemeManager")

local BODY = "IBM Plex Sans, 11"

-- A stand-in for a widget that was created without an explicit FONT, which is the
-- case the optimisation targets and the case the type scale falls into.
local function manager_with(theme_font)
	local mgr = setmetatable({}, { __index = ThemeManager })
	mgr._theme_font = theme_font
	mgr._iup = {
		GetAttribute = function() return nil end,
		SetAttribute = function() end,
		GetAllAttributes = function() return {} end,   -- no local FONT
	}
	mgr._orig = {}
	return mgr
end

-- Drive just the FONT decision in _applyElement by capturing what it would write.
local function font_written(theme_font, rule_font)
	local mgr = manager_with(theme_font)
	local written = {}
	mgr._iup.SetAttribute = function(_, attr, val) written[attr] = val end
	mgr._save = function() end
	mgr._mergeOriginals = function() end
	mgr._widgetKey = function() return "k" end

	ThemeManager._applyElement(mgr, {}, { label = { fg = "0 0 0", font = rule_font } },
		"label", nil, nil)
	return written.FONT
end

describe("Carbon type scale reaches widgets with no local font", function()
	it("skips the FONT write when the rule only restates the body font", function()
		-- The optimisation's intended case: DEFAULTFONT will deliver this, so
		-- writing it per widget buys nothing and costs a re-measure each.
		assert.is_nil(font_written(BODY, BODY))
	end)

	it("writes the FONT when the rule names a larger heading", function()
		-- heading-04. Inheritance cannot deliver a different size, so skipping
		-- this is what made every page title render at body size.
		assert.are.equal("IBM Plex Sans, 21", font_written(BODY, "IBM Plex Sans, 21"))
	end)

	it("writes the FONT when the rule differs only in weight", function()
		-- heading-compact-01 is the body size at a heavier weight; the string
		-- differs, so this must not be mistaken for the inheritable case.
		assert.are.equal("IBM Plex Sans, Bold 11", font_written(BODY, "IBM Plex Sans, Bold 11"))
	end)

	it("writes the FONT when the theme has no font of its own", function()
		-- With no theme font there is nothing for DEFAULTFONT to carry, so the
		-- skip can never be justified.
		assert.are.equal("IBM Plex Sans, 21", font_written(nil, "IBM Plex Sans, 21"))
	end)
end)

describe("the Carbon rule builder emits a real type scale", function()
	local carbon = require("core.classes.Themes.carbon_rules")

	it("gives headings distinct sizes rather than one body font", function()
		local rules = carbon.build({
			font = BODY, text = "0 0 0", textMuted = "1 1 1", bg = "2 2 2",
			surface = "3 3 3", surface2 = "4 4 4", accent = "5 5 5",
			accentText = "6 6 6", border = "7 7 7", borderStrong = "8 8 8",
		})

		-- Four distinct steps: if any two collapse, the scale has stopped being
		-- a scale and the hierarchy on screen goes with it.
		local seen = {}
		for _, role in ipairs({ "pagetitle", "sectiontitle", "pagesubtitle", "hint" }) do
			local f = rules[role] and rules[role].font
			assert.is_truthy(f, role .. " has no font")
			assert.is_nil(seen[f], role .. " reuses another role's font: " .. tostring(f))
			seen[f] = role
		end
	end)

	it("derives every heading from the palette's own family", function()
		-- A heading that names a second family is how a themed app ends up with
		-- one control in Segoe on a theme that asked for IBM Plex.
		local rules = carbon.build({
			font = "Example Sans Medium, 11", text = "0 0 0", textMuted = "1 1 1",
			bg = "2 2 2", surface = "3 3 3", surface2 = "4 4 4", accent = "5 5 5",
			accentText = "6 6 6", border = "7 7 7", borderStrong = "8 8 8",
		})
		for _, role in ipairs({ "pagetitle", "sectiontitle", "pagesubtitle", "hint" }) do
			assert.is_truthy(rules[role].font:find("Example Sans Medium", 1, true),
				role .. " lost the palette family: " .. rules[role].font)
		end
	end)
end)
