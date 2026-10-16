-- spec/theme_gradient_spec.lua — native gradient and rounded-corner attribute wiring.
--
-- The IUP fork registers CORNERRADIUS, GRADIENTCOLOR and GRADIENTDIRECTION on the
-- five fork-patched flat controls (flatbutton, flatframe, flatlabel, flattoggle,
-- dropbutton). ThemeManager:_attrsFromRule must emit those attributes from the rule
-- fields `radius`, `gradcolor` and `graddir` *only* for those classes; every other
-- class must stay unaffected.
--
-- Two guarantees are tested here:
--
--   1. One Dark Pro (opt-in): a gradient + radius rule processed for a supported flat
--      class produces GRADIENTCOLOR, GRADIENTDIRECTION, and CORNERRADIUS.
--
--   2. Carbon (opt-out): the same _attrsFromRule path produces NEITHER attribute for
--      a Carbon rule, because carbon_rules never sets `gradcolor` or `radius`. This
--      is the hard constraint: Carbon themes must stay flat and square.

local ThemeManager = require("core.classes.ThemeManager")

local function attrs_for(cls, rule)
	local mgr = setmetatable({}, { __index = ThemeManager })
	return ThemeManager._attrsFromRule(mgr, cls, rule)
end

-- A sentinel palette where every key returns "<key>" so assertions describe intent.
local function sentinel()
	return setmetatable({}, { __index = function(_, k) return "<" .. k .. ">" end })
end

describe("gradient and rounded-corner attribute wiring", function()

	describe("One Dark Pro / fluent_rules (gradient opt-in)", function()
		-- Build rules with a gradient-capable palette so gradcolor and radius are
		-- non-nil. The sentinel palette makes every token a "<name>" string, which
		-- is truthy and readable, so we can assert presence without hard-coding RGB.
		local fluent = require("core.classes.Themes.fluent_rules")
		local p = setmetatable({ gradEnabled = true, gradTop = "97 175 239",
			gradBottom = "198 120 221", radius = 6 }, {
			__index = function(_, k) return "<" .. k .. ">" end })
		local rules

		before_each(function()
			rules = fluent.build(p)
		end)

		it("emits GRADIENTCOLOR and GRADIENTDIRECTION for flatbutton", function()
			local attrs = attrs_for("flatbutton", rules.flatbutton)
			assert.is_truthy(attrs.GRADIENTCOLOR)
			assert.is_truthy(attrs.GRADIENTDIRECTION)
		end)

		it("emits CORNERRADIUS for flatbutton", function()
			local attrs = attrs_for("flatbutton", rules.flatbutton)
			assert.is_truthy(attrs.CORNERRADIUS)
			assert.are.equal("6", attrs.CORNERRADIUS)
		end)

		it("emits CORNERRADIUS for actionbutton role on flatbutton class", function()
			-- THEMEROLE-based theming still calls _attrsFromRule with cls="flatbutton"
			-- and the role rule; radius must reach the output the same way.
			local attrs = attrs_for("flatbutton", rules.actionbutton)
			assert.is_truthy(attrs.CORNERRADIUS)
			assert.is_truthy(attrs.GRADIENTCOLOR)
		end)

		it("emits all three attrs for the primary button", function()
			local attrs = attrs_for("flatbutton", rules.primary_btn)
			assert.is_truthy(attrs.CORNERRADIUS)
			assert.is_truthy(attrs.GRADIENTCOLOR)
			assert.is_truthy(attrs.GRADIENTDIRECTION)
		end)

		it("emits CORNERRADIUS for flatframe", function()
			local attrs = attrs_for("flatframe", rules.flatframe)
			assert.is_truthy(attrs.CORNERRADIUS)
		end)

		it("emits CORNERRADIUS for flattoggle", function()
			local attrs = attrs_for("flattoggle", rules.flattoggle)
			assert.is_truthy(attrs.CORNERRADIUS)
		end)

		it("emits CORNERRADIUS for dropbutton", function()
			local attrs = attrs_for("dropbutton", rules.dropbutton)
			assert.is_truthy(attrs.CORNERRADIUS)
			assert.is_truthy(attrs.GRADIENTCOLOR)
		end)

		it("emits gradient and radius for accentstrip on flatlabel class", function()
			-- The accent strip is a flatlabel carrying a HORIZONTAL gradient; it is
			-- the most visible gradient surface in the chrome.
			local attrs = attrs_for("flatlabel", rules.accentstrip)
			assert.is_truthy(attrs.GRADIENTCOLOR)
			assert.are.equal("HORIZONTAL", attrs.GRADIENTDIRECTION)
			assert.is_truthy(attrs.CORNERRADIUS)
		end)

		it("does NOT emit gradient attrs for non-flat classes (e.g. label)", function()
			-- Plain IupLabel has no GRADIENTCOLOR registration; setting it would be
			-- a silent waste. Confirm _attrsFromRule skips the block for it.
			local fake_rule = { bg = "<bg>", gradcolor = "<grad>", radius = 6 }
			local attrs = attrs_for("label", fake_rule)
			assert.is_nil(attrs.GRADIENTCOLOR)
			assert.is_nil(attrs.CORNERRADIUS)
		end)
	end)

	describe("Carbon / carbon_rules (gradient opt-out)", function()
		local carbon = require("core.classes.Themes.carbon_rules")
		local rules

		before_each(function()
			-- A representative Carbon palette: no gradEnabled, no gradTop/Bottom,
			-- no radius.  Matches the shape every Carbon theme provides.
			rules = carbon.build(sentinel())
		end)

		-- This is the hard constraint: Carbon themes must stay sharp and flat.
		it("produces NO GRADIENTCOLOR for a Carbon flatbutton", function()
			-- carbon_rules has no flatbutton entry but actionbutton (or similar)
			-- falls back to the class rule; either way no gradcolor/radius is set.
			-- We test all button-like rules that carbon_rules does define.
			for _, role in ipairs({ "button", "toggle" }) do
				if rules[role] then
					local attrs = attrs_for("flatbutton", rules[role])
					assert.is_nil(attrs.GRADIENTCOLOR,
						role .. " produced unexpected GRADIENTCOLOR")
					assert.is_nil(attrs.CORNERRADIUS,
						role .. " produced unexpected CORNERRADIUS")
				end
			end
		end)

		it("produces NO GRADIENTCOLOR or CORNERRADIUS for any Carbon rule on flatbutton", function()
			-- Belt-and-suspenders: walk every rule carbon_rules returns and confirm
			-- none of them would emit gradient/radius attributes when applied to a
			-- flatbutton.  This catches a future rule addition that accidentally
			-- carries the fields.
			for name, rule in pairs(rules) do
				if type(rule) == "table" then
					local attrs = attrs_for("flatbutton", rule)
					assert.is_nil(attrs.GRADIENTCOLOR,
						"carbon rule '" .. name .. "' produced unexpected GRADIENTCOLOR")
					assert.is_nil(attrs.CORNERRADIUS,
						"carbon rule '" .. name .. "' produced unexpected CORNERRADIUS")
				end
			end
		end)
	end)
end)
