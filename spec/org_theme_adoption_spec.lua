local SettingsManager = require("core.classes.SettingsManager")

local function manager(user, saves)
	local s = setmetatable({ _user = user, _locked = {}, _org_defaults = {} }, { __index = SettingsManager })
	function s:save() return saves ~= false end
	return s
end

local function profile(theme, locked)
	return { id = "acme", adopt_theme = true, settings = {
		theme = theme or "acme_light", theme_light = "acme_light", theme_dark = "acme_dark",
	}, locked = locked or {} }
end

describe("org theme adoption", function()
	it("adopts once per theme value, preserves later choices and other markers", function()
		local s = manager({ theme = "classic_dark", theme_light = "classic", theme_dark = "classic_dark",
			org_theme_applied = { other = "other_dark" } })
		s:applyProfile(profile())
		assert.equal("acme_light", s:get("theme"))
		assert.equal("acme_dark", s:get("theme_dark"))
		assert.same({ acme = "acme_light", other = "other_dark" }, s._user.org_theme_applied)
		s:set("theme", "lunar_dark")
		s:applyProfile(profile())
		assert.equal("lunar_dark", s:get("theme"))
		s:applyProfile(profile("acme_v2"))
		assert.equal("acme_v2", s:get("theme"))
	end)

	it("does nothing without opt-in and keeps locked user values", function()
		local s = manager({ theme = "mine", theme_dark = "mine_dark" })
		local p = profile(nil, { theme_dark = true })
		p.adopt_theme = false
		s:applyProfile(p)
		assert.equal("mine", s:get("theme"))
		assert.is_nil(s._user.org_theme_applied)
		p.adopt_theme = true
		s:applyProfile(p)
		assert.equal("mine_dark", s._user.theme_dark)
		assert.equal("acme_dark", s:get("theme_dark"))
	end)

	it("rolls back failed saves and retries, including malformed markers", function()
		local user = { theme = "mine", theme_light = "light", org_theme_applied = "bad" }
		local s = manager(user, false)
		s:applyProfile(profile())
		assert.same({ theme = "mine", theme_light = "light", org_theme_applied = "bad" }, user)
		function s:save() return true end
		s:applyProfile(profile())
		assert.equal("acme_light", s:get("theme"))
	end)
end)
