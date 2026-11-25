-- Liquid Glass motion: floating menus open with a 150 ms fade and 4 px lift, buttons ease
-- their hover over 110 ms; both are instant without motion, and nothing runs at rest.
describe("glass motion", function()
	local saved = {}
	local clock, animated, enabled
	local palette = { glass = true }
	before_each(function()
		clock, animated, enabled = 0, 0, true
		for _, name in ipairs({ "core.imgui.Runtime", "core.ui.ThemeReactor" }) do saved[name] = package.loaded[name] end
		package.loaded["core.imgui.Runtime"] = { now = function() return clock end, animate = function() animated = animated + 1 end }
		package.loaded["core.ui.ThemeReactor"] = {
			palette = function() return palette end,
			themeManager = function() return { _motion = { enabled = function() return enabled end, _scale = 1 } } end,
		}
	end)
	after_each(function()
		for name, value in pairs(saved) do package.loaded[name] = value end
	end)

	it("fades a menu in over 150 ms and then stops asking for frames", function()
		local menu = require("core.imgui.widgets.menu")
		local state = {}
		assert.near(0, menu._entrance(state), 1e-9)
		clock = 0.075
		local mid = menu._entrance(state)
		assert.is_true(mid > 0.5 and mid < 1)
		clock = 0.16
		local before = animated
		assert.equal(1, menu._entrance(state))
		assert.equal(before, animated)
	end)

	it("opens a menu at once without motion", function()
		enabled = false
		assert.equal(1, require("core.imgui.widgets.menu")._entrance({}))
		assert.equal(0, animated)
	end)

	it("eases a hover in and back out over 110 ms", function()
		local mix = require("core.imgui.widgets.flatbutton")._hover_mix
		local d = {}
		assert.equal(0, mix(d, false))
		assert.near(0, mix(d, true), 1e-9)
		clock = 0.055
		local half = mix(d, true)
		assert.is_true(half > 0.4 and half < 0.6)
		clock = 0.2
		assert.equal(1, mix(d, true))
		assert.equal(1, mix(d, false))
		clock = 0.255
		assert.is_true(mix(d, false) < 0.6)
	end)

	it("switches a hover at once without motion or outside glass themes", function()
		local mix = require("core.imgui.widgets.flatbutton")._hover_mix
		enabled = false
		assert.equal(1, mix({}, true))
		enabled = true
		palette = { glass = false }
		assert.equal(1, mix({}, true))
		palette = { glass = true }
	end)
end)
