-- spec/theme_flattabs_spec.lua — tab strip theming.
--
-- The host puts a "+ new tab group" button on every tab strip using IupFlatTabs'
-- EXTRABUTTONS facility (see core.classes.TabGroups). That button is owner-drawn
-- by the control, NOT native — but when its per-button colours are unset,
-- iFlatTabsRedraw falls back to IUP_FLAT_HIGHCOLOR / IUP_FLAT_PRESSCOLOR, which
-- are IUP's own blue defaults and ignore the theme completely. The result looks
-- exactly like an unthemed native control, which is a misleading symptom: the fix
-- is supplying colours, not replacing the widget.
--
-- These tests pin that every shipped theme supplies them, so the button can never
-- silently revert to blue.

local ThemeManager = require("core.classes.ThemeManager")

-- A palette that reports which key each rule field came from, so the assertions
-- describe intent ("the hover colour is the theme's surface2") rather than
-- hard-coding RGB values that legitimately differ per theme.
local function sentinel_palette()
	return setmetatable({}, { __index = function(_, key) return "<" .. key .. ">" end })
end

local function rules_for(module_name)
	return require("core.classes.Themes." .. module_name).build(sentinel_palette())
end

-- _attrsFromRule is a pure rule -> attribute mapping, so it can be called on a
-- bare instance without a live IUP tree.
local function attrs_for(cls, rule)
	local mgr = setmetatable({}, { __index = ThemeManager })
	return ThemeManager._attrsFromRule(mgr, cls, rule)
end

-- The hover token each builder is expected to reach for. Carbon distinguishes
-- `$layer-hover-01` from `$layer-selected-01`; Fluent's palette (One Dark Pro) has
-- not been through that split and still carries a single `surface2`, so the two
-- builders legitimately name different keys for the same intent.
local RULE_MODULES = {
	{ name = "carbon_rules", hover = "<layerHover01>" },
	{ name = "fluent_rules", hover = "<surface2>" },
}

describe("flat tab strip theming", function()
	for _, mod in ipairs(RULE_MODULES) do
		local module_name = mod.name
		describe(module_name, function()
			local rules

			before_each(function()
				rules = rules_for(module_name)
			end)

			it("gives the tab strip a hover and pressed colour", function()
				-- Without these two the extra-button colours below have nothing to
				-- resolve to and the control falls back to blue.
				assert.is_truthy(rules.flattabs.hover)
				assert.is_truthy(rules.flattabs.selbg)
			end)

			it("distinguishes the selected tab from the strip behind it", function()
				-- BGCOLOR is the selected tab and the page below it; TABSBACKCOLOR
				-- is the strip the unselected tabs sit on. Driving both from the
				-- same rule field made a selected tab indistinguishable from its
				-- neighbours, which is most of what stopped the tab strip reading
				-- as Carbon's contained tabs.
				local attrs = attrs_for("flattabs", rules.flattabs)
				assert.is_truthy(attrs.BGCOLOR)
				assert.is_truthy(attrs.TABSBACKCOLOR)
				if rules.flattabs.tabsbg then
					assert.are_not.equal(attrs.BGCOLOR, attrs.TABSBACKCOLOR)
				end
			end)

			it("themes the extra buttons drawn at the end of the strip", function()
				local attrs = attrs_for("flattabs", rules.flattabs)

				assert.are.equal("<text>", attrs.EXTRAFORECOLOR1)
				-- The Carbon palettes used to collapse hover, selection and
				-- elevation into one `surface2`; asserting the specific hover
				-- token means a future palette that distinguishes them cannot
				-- silently regress the extra buttons to a selection colour.
				assert.are.equal(mod.hover, attrs.EXTRAHIGHCOLOR1)
				assert.is_truthy(attrs.EXTRAPRESSCOLOR1)
				assert.is_truthy(attrs.EXTRABORDERCOLOR1)
			end)

			it("themes all three extra-button slots IupFlatTabs supports", function()
				-- An extension may add its own; only slot 1 is the host's.
				local attrs = attrs_for("flattabs", rules.flattabs)
				for i = 1, 3 do
					assert.is_truthy(attrs["EXTRAHIGHCOLOR" .. i])
					assert.is_truthy(attrs["EXTRAPRESSCOLOR" .. i])
				end
			end)

			it("defines every role the group name/rename prompt uses", function()
				-- core.ui.NameDialog is built from flat controls carrying these roles.
				-- A missing role means an unthemed control in that dialog.
				for _, role in ipairs({ "primary_btn", "actionbutton",
				                        "settingslabel", "text" }) do
					assert.is_truthy(rules[role], role .. " is not defined")
				end
			end)
		end)
	end
end)
