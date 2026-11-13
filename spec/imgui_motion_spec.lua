-- spec/imgui_motion_spec.lua -- widget motion on the ImGui host (core.imgui.motion) and
-- the tab strip that uses it: Carbon durations and curves by role, under the host's
-- motion settings, with every value landing on its target.

local Null = require("core.imgui.backend.Null")
local R = require("core.imgui.Runtime")
local Element = require("core.imgui.Element")
local Color = require("core.imgui.Color")
local iup = require("core.imgui.iup")
local motion = require("core.imgui.motion")
local Tokens = require("core.lib.MotionTokens")

describe("core.imgui.motion", function()
	local B, st
	before_each(function()
		B = Null.new()
		R.init(B)
		motion.attach(nil)
		motion.setEnabled(true)
		st = { data = {} }
	end)
	after_each(function() motion.setEnabled(true) end)

	local spec = { duration = 100, curve = "standard", style = "productive" }

	it("draws the first value as is and eases a change over the role's duration", function()
		assert.equal(0, motion.number(st, "x", 0, spec))
		assert.equal(0, motion.number(st, "x", 100, spec)) -- starts where it was
		B.advance(0.05)
		local mid = motion.number(st, "x", 100, spec)
		assert.is_true(mid > 0 and mid < 100, "half way: " .. mid)
		assert.is_true(motion.busy(st))
		B.advance(0.06)
		assert.equal(100, motion.number(st, "x", 100, spec))
		assert.is_false(motion.busy(st))
	end)

	it("follows Carbon's standard curve: ahead of linear at the midpoint", function()
		motion.number(st, "x", 0, spec)
		motion.number(st, "x", 100, spec)
		B.advance(0.05)
		local v = motion.number(st, "x", 100, spec)
		local ease = require("core.lib.MotionEasing").curve(unpack(Tokens.easing("standard", "productive")))
		assert.is_true(math.abs(v - 100 * ease(0.5)) < 0.5)
		assert.is_true(v > 50)
	end)

	it("retargets from where the value is, mid-flight", function()
		motion.number(st, "x", 0, spec)
		motion.number(st, "x", 100, spec)
		B.advance(0.05)
		local mid = motion.number(st, "x", 100, spec)
		assert.equal(mid, motion.number(st, "x", 0, spec)) -- turns back from there
		B.advance(0.2)
		assert.equal(0, motion.number(st, "x", 0, spec))
	end)

	it("lands at once with motion off", function()
		motion.setEnabled(false)
		motion.number(st, "x", 0, spec)
		assert.equal(100, motion.number(st, "x", 100, spec))
		assert.is_false(motion.busy(st))
	end)

	it("with an ident, eases only when the ident changes", function()
		motion.number(st, "x", 10, spec, { ident = "a" })
		assert.equal(30, motion.number(st, "x", 30, spec, { ident = "a" })) -- same thing moved: at once
		assert.equal(30, motion.number(st, "x", 80, spec, { ident = "b" })) -- another thing: eases
		B.advance(0.2)
		assert.equal(80, motion.number(st, "x", 80, spec, { ident = "b" }))
	end)

	it("eases two values on one clock (an indicator's position and length)", function()
		motion.pair(st, "ind", 0, 40, spec, { ident = 1 })
		motion.pair(st, "ind", 100, 80, spec, { ident = 2 })
		B.advance(0.05)
		local x, w = motion.pair(st, "ind", 100, 80, spec, { ident = 2 })
		assert.is_true(x > 0 and x < 100 and w > 40 and w < 80)
		-- both have covered the same share of their way
		assert.is_true(math.abs(x / 100 - (w - 40) / 40) < 0.01)
	end)

	it("fades a colour in from nothing and out to nothing", function()
		assert.is_nil(motion.color(st, "fill", nil, spec))
		assert.equal(Color.pack(200, 0, 0, 0), motion.color(st, "fill", "200 0 0", spec))
		B.advance(0.05)
		local _, _, _, a = Color.unpack(motion.color(st, "fill", "200 0 0", spec))
		assert.is_true(a > 0 and a < 255)
		B.advance(0.1)
		assert.equal(Color.parse("200 0 0"), motion.color(st, "fill", "200 0 0", spec))
		motion.color(st, "fill", nil, spec)
		B.advance(0.2)
		assert.is_nil(motion.color(st, "fill", nil, spec))
	end)

	it("takes the director's settings, scale and theme roles", function()
		local d = {
			on = true, k = 1, roles = {},
			enabled = function(self) return self.on end,
			scale = function(self) return self.k end,
			role = function(self, name) return Tokens.role(name, self.roles) end,
		}
		motion.attach(d)
		-- the hover token is fast_01 (70 ms)
		motion.number(st, "h", 0, "hover")
		motion.number(st, "h", 1, "hover")
		B.advance(0.069)
		assert.is_true(motion.number(st, "h", 1, "hover") < 1)
		B.advance(0.002)
		assert.equal(1, motion.number(st, "h", 1, "hover"))
		-- a theme slows it down
		d.roles = { hover = { duration = 300 } }
		motion.number(st, "h", 0, "hover")
		B.advance(0.2)
		assert.is_true(motion.number(st, "h", 0, "hover") > 0)
		-- the user turns motion off: at once
		d.on = false
		assert.equal(1, motion.number(st, "h", 1, "hover"))
	end)

	it("keeps the frame loop running while a value moves", function()
		local requested = 0
		local animate = R.animate
		R.animate = function() requested = requested + 1 end
		motion.number(st, "x", 0, spec)
		motion.number(st, "x", 100, spec)
		B.advance(0.05)
		motion.number(st, "x", 100, spec)
		B.advance(0.1)
		motion.number(st, "x", 100, spec)
		R.animate = animate
		assert.equal(2, requested) -- when it starts and mid-flight, not after landing
	end)
end)

describe("the tab strip's motion on the ImGui host", function()
	local B, tabs, LINE
	before_each(function()
		B = Null.new({ w = 600, h = 300 })
		R.init(B)
		motion.attach(nil)
		motion.setEnabled(true)
		LINE = Color.parse("255 0 0")
		tabs = iup.flattabs{ iup.vbox{}, iup.vbox{}, iup.vbox{},
			TABTITLE0 = "One", TABTITLE1 = "Second tab", TABTITLE2 = "Three",
			TABSACTIVELINE = "255 0 0", TABSHIGHCOLOR = "0 0 200", TABSFORECOLOR = "100 100 100",
			HIGHCOLOR = "250 250 250", FORECOLOR = "240 240 240", RASTERSIZE = "600x200" }
		iup.Show(iup.dialog{ tabs, RASTERSIZE = "600x300" })
		R.frame()
	end)
	after_each(function() motion.setEnabled(true) end)

	-- the indicator's x and width in the last frame
	local function indicator()
		for _, c in ipairs(B.lastFrame()) do
			if c[1] == "rect_filled" and c[6] == LINE and math.abs((c[5] - c[3]) - 2) < 0.01 then return c[2], c[4] - c[2] end
		end
	end
	local function tab_x(pos)
		for x = 0, 599 do if iup.ConvertXYToPos(tabs, x, 6) == pos then return x end end
	end

	it("slides the indicator from the old tab to the new one and lands under it", function()
		local x0, w0 = indicator()
		assert.is_not_nil(x0)
		iup.SetAttribute(tabs, "VALUEPOS", "2")
		R.frame()
		local x1 = indicator()
		assert.equal(x0, x1) -- the first frame after the switch is where it was
		B.advance(0.06); R.frame()
		local xm, wm = indicator()
		assert.is_true(xm > x0, "on its way: " .. xm)
		B.advance(0.5); R.frame()
		local xe, we = indicator()
		assert.equal(tab_x(2) + 8, xe)
		assert.is_true(we ~= w0) -- stretched to the new tab's width
		assert.is_true(xm < xe)
		assert.is_true(wm ~= nil)
	end)

	it("puts the indicator under the new tab at once with motion off", function()
		motion.setEnabled(false)
		iup.SetAttribute(tabs, "VALUEPOS", "2")
		R.frame()
		assert.equal(tab_x(2) + 8, (indicator()))
	end)

	it("eases a tab's hover fill in at the hover token", function()
		local HL = Color.parse("0 0 200")
		local function hover_fill()
			for _, c in ipairs(B.lastFrame()) do
				if c[1] == "rect_filled" then
					local r, g, b, a = Color.unpack(c[6])
					if r == 0 and g == 0 and b == 200 then return a end
				end
			end
		end
		local x = tab_x(1) + 5
		B.queue({ events = { { type = "move", x = x, y = 6 } } }); R.frame()
		local a0 = hover_fill()
		assert.is_true(a0 == nil or a0 == 0, "starts transparent")
		B.advance(0.035); R.frame()
		local am = hover_fill()
		assert.is_true(am and am > 0 and am < 255, "half way in: " .. tostring(am))
		B.advance(0.05); R.frame()
		assert.equal(255, hover_fill())
		assert.is_not_nil(HL)
	end)
end)
