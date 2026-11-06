--- The grid, the seek bar and the rows' new colours, in every rules builder.

local carbon = require("core.classes.Themes.carbon_rules")
local fluent = require("core.classes.Themes.fluent_rules")
local lunar = require("core.classes.Themes.lunar_rules")
local ThemeManager = require("core.classes.ThemeManager")

local function palette()
	local p = {
		bg = "10 10 10", layer01 = "20 20 20", layer02 = "30 30 30",
		layerHover01 = "40 40 40", layerSelected01 = "50 50 50",
		borderSubtle01 = "60 60 60", borderStrong01 = "70 70 70",
		text = "200 200 200", textMuted = "150 150 150",
		accent = "100 100 250", accentText = "255 255 255",
		error = "220 30 40", success = "30 160 70", warning = "230 190 120",
		warningText = "10 10 10", info = "80 180 190",
		font = "Segoe UI, 10",
		gradTop = "100 100 250", gradBottom = "50 50 120",
		radius = 4, radiusFrame = 6,
		gradEnabled = true, accentHover = "120 120 255",
	}
	p.surface, p.surface2 = p.layer01, p.layerHover01
	p.border, p.borderStrong = p.borderSubtle01, p.borderStrong01
	p.listBg, p.listText, p.listSelText = p.layer01, p.text, p.accent
	return p
end

for name, builder in pairs({ carbon = carbon, fluent = fluent, lunar = lunar }) do
	describe(name .. " rules", function()
		local rules = builder.build(palette())

		it("give the grid every colour it paints with", function()
			local attrs = ThemeManager._attrsFromRule({}, "flatgrid", rules.flatgrid)
			for _, attr in ipairs({ "BGCOLOR", "FGCOLOR", "SECONDARYCOLOR", "PLACEHOLDERCOLOR", "HLCOLOR", "ITEMMARKERCOLOR", "ITEMRADIUS", "FONT" }) do
				assert.is_truthy(attrs[attr], attr)
			end
		end)

		it("keep a chosen row apart from a row under the pointer", function()
			local rule = { selbg = "1 2 3", hover = "4 5 6", seltext = "7 8 9", bg = "0 0 0" }
			local attrs = ThemeManager._attrsFromRule({}, "flatrows", rule)
			assert.equal("1 2 3", attrs.PSCOLOR)
			assert.equal("4 5 6", attrs.HLCOLOR)
		end)

		it("give the seek bar every colour it paints with", function()
			local attrs = ThemeManager._attrsFromRule({}, "flatseek", rules.flatseek)
			for _, attr in ipairs({ "BGCOLOR", "TRACKCOLOR", "BUFFERCOLOR", "PSCOLOR", "MARKCOLOR" }) do
				assert.is_truthy(attrs[attr], attr)
			end
		end)

		it("give rows a placeholder and a header", function()
			local attrs = ThemeManager._attrsFromRule({}, "flatrows", rules.flatrows)
			assert.is_truthy(attrs.PLACEHOLDERCOLOR)
			assert.is_truthy(attrs.HEADERCOLOR)
			assert.is_truthy(attrs.BORDERCOLOR)
		end)
	end)
end
