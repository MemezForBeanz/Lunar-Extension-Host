-- spec/motion_easing_spec.lua — core.lib.MotionEasing, the cubic-bezier solver.
--
-- Easing is evaluated once per animation per frame, so the production path is a
-- precomputed FFI sample table rather than an iterative solve. That optimisation is
-- only safe if it agrees with the real curve, and "looks about right" is not a
-- standard anyone can check.
--
-- So the table is tested against `solve()`, an independent Newton-Raphson +
-- bisection implementation in the same module. Two implementations of the same
-- mathematics, cross-checked at a thousand points: a mistake in the fast path has
-- to be reproduced exactly in the slow one to go unnoticed.
--
-- The rest pins the properties an animation driver actually depends on — exact
-- endpoints, monotonicity, clamping — because violating any of them shows up as a
-- visible glitch rather than as a slightly wrong number.

local Easing = require("core.lib.MotionEasing")
local Tokens = require("core.lib.MotionTokens")

local function each_carbon_curve(fn)
	for _, curve in ipairs({ "standard", "entrance", "exit" }) do
		for _, style in ipairs({ "productive", "expressive" }) do
			fn(curve, style, Tokens.easing(curve, style))
		end
	end
end

describe("MotionEasing endpoints", function()
	it("starts at exactly 0 and ends at exactly 1", function()
		-- Not "close to". An animation's final frame writes this value directly, so
		-- a curve ending at 0.9999 leaves every animated property a hair short of
		-- its destination — and those errors are permanent.
		each_carbon_curve(function(curve, style, points)
			local ease = Easing.fromPoints(points)
			assert.are.equal(0, ease(0), curve .. "/" .. style .. " at t=0")
			assert.are.equal(1, ease(1), curve .. "/" .. style .. " at t=1")
		end)
	end)

	it("clamps input outside 0..1", function()
		-- Floating-point accumulation can hand the last frame a t a shade over 1.
		local ease = Easing.fromPoints(Tokens.easing("standard"))
		assert.are.equal(0, ease(-0.5))
		assert.are.equal(1, ease(1.5))
		assert.are.equal(0, ease(-math.huge))
		assert.are.equal(1, ease(math.huge))
	end)
end)

describe("MotionEasing correctness", function()
	it("agrees with the analytic solver across every Carbon curve", function()
		each_carbon_curve(function(curve, style, points)
			local ease = Easing.fromPoints(points)
			local worst = 0
			for i = 0, 1000 do
				local t = i / 1000
				local d = math.abs(ease(t) - Easing.solve(t, points[1], points[2], points[3], points[4]))
				if d > worst then worst = d end
			end
			assert.is_true(worst < 5e-5,
				("%s/%s deviated by %.3e"):format(curve, style, worst))
		end)
	end)

	it("is monotonic, so animations never visibly backtrack", function()
		each_carbon_curve(function(curve, style, points)
			local ease = Easing.fromPoints(points)
			local prev = -1
			for i = 0, 1000 do
				local v = ease(i / 1000)
				assert.is_true(v >= prev - 1e-9,
					("%s/%s went backwards at t=%.3f"):format(curve, style, i / 1000))
				prev = v
			end
		end)
	end)

	it("stays within 0..1 for the standard and entrance curves", function()
		-- These have no overshoot by construction. Carbon explicitly rejects easing
		-- that suggests bounce or stretch, so a curve leaving the unit range would
		-- mean the wrong control points had been entered.
		for _, curve in ipairs({ "standard", "entrance" }) do
			for _, style in ipairs({ "productive", "expressive" }) do
				local ease = Easing.fromPoints(Tokens.easing(curve, style))
				for i = 0, 500 do
					local v = ease(i / 500)
					assert.is_true(v >= -1e-9 and v <= 1 + 1e-9,
						("%s/%s left the unit range: %s"):format(curve, style, tostring(v)))
				end
			end
		end
	end)

	it("accelerates then decelerates rather than moving linearly", function()
		-- The whole reason easing exists: Carbon states that strictly linear
		-- movement reads as unnatural. A curve that matches linear everywhere would
		-- silently defeat the motion system.
		local ease = Easing.fromPoints(Tokens.easing("standard", "productive"))
		local deviated = false
		for i = 1, 99 do
			local t = i / 100
			if math.abs(ease(t) - t) > 0.02 then deviated = true break end
		end
		assert.is_true(deviated, "standard/productive is indistinguishable from linear")
	end)
end)

describe("MotionEasing caching and construction", function()
	it("returns the same function for the same control points", function()
		-- There are only six Carbon curves but they are requested on every
		-- animation, so the cache is what keeps the sample tables from being
		-- rebuilt thousands of times.
		local a = Easing.curve(0.2, 0, 0.38, 0.9)
		local b = Easing.curve(0.2, 0, 0.38, 0.9)
		assert.are.equal(a, b)
	end)

	it("distinguishes different control points", function()
		assert.are_not.equal(Easing.curve(0.2, 0, 0.38, 0.9), Easing.curve(0, 0, 0.3, 1))
	end)

	it("supports the linear curve for non-visual interpolation", function()
		local ease = Easing.curve(0, 0, 1, 1)
		for i = 0, 10 do
			local t = i / 10
			assert.is_true(math.abs(ease(t) - t) < 1e-9)
		end
	end)

	it("degrades to linear when handed something that is not a point table", function()
		local ease = Easing.fromPoints(nil)
		assert.are.equal(0, ease(0))
		assert.are.equal(1, ease(1))
		assert.is_true(math.abs(ease(0.5) - 0.5) < 1e-9)
	end)
end)
