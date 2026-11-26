local motion = require("core.imgui.motion")
local Color = require("core.imgui.Color")

-- A theme change snaps every colour tween: a hover or selection ease never crosses a switch
-- (between two themes' colours a label passes through the contrast of neither).
describe("imgui motion snap", function()
	local saved
	before_each(function()
		saved = package.loaded["core.imgui.Runtime"]
		local clock = 0
		package.loaded["core.imgui.Runtime"] = { now = function() clock = clock + 0.001; return clock end, animate = function() end }
		motion.setEnabled(true)
	end)
	after_each(function() package.loaded["core.imgui.Runtime"] = saved end)
	it("eases a colour change, but lands a theme change at once", function()
		local st = { data = {} }
		motion.color(st, "fg", "0 0 0", { duration = 1000 })
		local mid = motion.color(st, "fg", "255 255 255", { duration = 1000 })
		assert.are_not.equal(Color.parse("255 255 255"), mid)
		motion.snap()
		assert.equal(Color.parse("10 20 30"), motion.color(st, "fg", "10 20 30", { duration = 1000 }))
	end)
end)
