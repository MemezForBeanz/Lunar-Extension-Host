local OrgProfile = require("core.lib.OrgProfile")

describe("org branding", function()
	it("validates each variant independently and restricts icons to SVG", function()
		local p = assert(OrgProfile.validate({ schema = 1, id = "acme", name = "Acme",
			adopt_theme = true, brand = { icon = "mark.png", logo = {
				light = "logo.png", dark = "../outside.png", default = "missing.svg",
				themes = { custom = "mark.svg", invalid = 42, absolute = "/logo.png" },
			} } }, "pack", { fs = { exists = function(path) return not path:find("missing", 1, true) end } }))
		assert.is_true(p.adopt_theme)
		assert.is_nil(p.brand.icon)
		assert.is_nil(p.brand.logo.dark)
		assert.is_nil(p.brand.logo.default)
		assert.is_truthy(p.brand.logo.light:match("logo%.png$"))
		assert.is_truthy(p.brand.logo.themes.custom:match("mark%.svg$"))
		assert.equal(5, #p.warnings)
	end)

	it("resolves exact theme, appearance, default, then nothing", function()
		local brand = { logo = { themes = { custom = "exact" }, dark = "dark", light = "light", default = "fallback" } }
		assert.equal("exact", OrgProfile.logoFor(brand, "custom", true))
		assert.equal("dark", OrgProfile.logoFor(brand, "other", true))
		assert.equal("light", OrgProfile.logoFor(brand, "other", false))
		brand.logo.dark = nil
		assert.equal("fallback", OrgProfile.logoFor(brand, "other", true))
		brand.logo.default = nil
		assert.is_nil(OrgProfile.logoFor(brand, "other", true))
		assert.equal("all.svg", OrgProfile.logoFor({ logo = "all.svg" }, "other", true))
		assert.is_nil(OrgProfile.logoFor(nil, "other", true))
	end)
end)
