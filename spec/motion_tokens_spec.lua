-- spec/motion_tokens_spec.lua — core.lib.MotionTokens, the Carbon motion vocabulary.
--
-- These are the published IBM Carbon values, not tuning constants. If a duration
-- or a bezier control point changes here, every animation in the app changes with
-- it, and the app stops matching the design system its themes and layout are built
-- on. So they are pinned literally: the test is a transcription of the spec, and a
-- diff against it is the signal that someone edited a number they should not have.
--
-- The derived arithmetic (dynamic duration, stagger, corner paths) is pinned by
-- property rather than by value, because those are judgement calls that may be
-- retuned — what must not break is the guarantee each one makes.

local Tokens = require("core.lib.MotionTokens")

describe("MotionTokens durations", function()
	it("matches the published Carbon duration scale", function()
		assert.are.equal(70,  Tokens.DURATION.fast_01)
		assert.are.equal(110, Tokens.DURATION.fast_02)
		assert.are.equal(150, Tokens.DURATION.moderate_01)
		assert.are.equal(240, Tokens.DURATION.moderate_02)
		assert.are.equal(400, Tokens.DURATION.slow_01)
		assert.are.equal(700, Tokens.DURATION.slow_02)
	end)
end)

describe("MotionTokens easing curves", function()
	-- The six curves, exactly as Carbon publishes them in cubic-bezier notation.
	local EXPECTED = {
		{ "standard", "productive", { 0.2, 0,    0.38, 0.9 } },
		{ "standard", "expressive", { 0.4, 0.14, 0.3,  1   } },
		{ "entrance", "productive", { 0,   0,    0.38, 0.9 } },
		{ "entrance", "expressive", { 0,   0,    0.3,  1   } },
		{ "exit",     "productive", { 0.2, 0,    1,    0.9 } },
		{ "exit",     "expressive", { 0.4, 0.14, 1,    1   } },
	}

	for _, case in ipairs(EXPECTED) do
		local curve, style, points = case[1], case[2], case[3]
		it("pins " .. curve .. "/" .. style, function()
			local got = Tokens.easing(curve, style)
			for i = 1, 4 do
				assert.are.equal(points[i], got[i])
			end
		end)
	end

	it("defaults to standard/productive", function()
		local def = Tokens.easing()
		local std = Tokens.easing("standard", "productive")
		for i = 1, 4 do assert.are.equal(std[i], def[i]) end
	end)

	it("falls back to productive for an unknown style", function()
		local got = Tokens.easing("entrance", "nonsense")
		local want = Tokens.easing("entrance", "productive")
		for i = 1, 4 do assert.are.equal(want[i], got[i]) end
	end)

	it("falls back to standard for an unknown curve", function()
		local got = Tokens.easing("nonsense", "productive")
		local want = Tokens.easing("standard", "productive")
		for i = 1, 4 do assert.are.equal(want[i], got[i]) end
	end)
end)

describe("MotionTokens dynamic duration", function()
	it("grows with distance", function()
		assert.is_true(Tokens.duration(800) > Tokens.duration(200))
	end)

	it("grows sub-linearly, so long movements stay brisk", function()
		-- Carbon's scale is deliberately non-linear: quadrupling the distance must
		-- cost far less than four times the duration, or large movements feel
		-- sluggish long before they look wrong on paper.
		local short = Tokens.duration(200)
		local long  = Tokens.duration(800)
		assert.is_true(long < short * 4)
	end)

	it("clamps productive motion to the token range", function()
		assert.is_true(Tokens.duration(0) >= Tokens.DURATION.fast_02)
		assert.is_true(Tokens.duration(100000) <= Tokens.DURATION.slow_01)
	end)

	it("clamps expressive motion to its own, slower range", function()
		assert.is_true(Tokens.duration(0, "expressive") >= Tokens.DURATION.moderate_01)
		assert.is_true(Tokens.duration(100000, "expressive") <= Tokens.DURATION.slow_02)
	end)

	it("makes expressive motion slower than productive at the same distance", function()
		assert.is_true(Tokens.duration(400, "expressive") > Tokens.duration(400, "productive"))
	end)

	it("treats negative distance as travel, not as an error", function()
		assert.are.equal(Tokens.duration(300), Tokens.duration(-300))
	end)

	it("survives a nil or non-numeric distance", function()
		assert.is_true(Tokens.duration(nil) > 0)
		assert.is_true(Tokens.duration("banana") > 0)
	end)
end)

describe("MotionTokens stagger", function()
	it("gives the first element no delay", function()
		assert.are.equal(0, Tokens.stagger(1, 10))
	end)

	it("spaces elements by the requested step", function()
		assert.are.equal(40, Tokens.stagger(3, 10, 20))
	end)

	it("keeps the whole sequence within Carbon's 500ms ceiling", function()
		-- The reason the total matters: a fixed per-item delay turns a long list
		-- into an unbearable wait. Carbon caps the sequence, so the step has to
		-- compress as the list grows.
		for _, count in ipairs({ 2, 10, 26, 100, 1000 }) do
			local last = Tokens.stagger(count, count, 20)
			assert.is_true(last <= 500,
				("sequence of %d ended at %sms"):format(count, tostring(last)))
		end
	end)

	it("does not stretch short sequences to fill the ceiling", function()
		assert.are.equal(20, Tokens.stagger(2, 3, 20))
	end)

	it("returns no delay for a single element", function()
		assert.are.equal(0, Tokens.stagger(1, 1))
		assert.are.equal(0, Tokens.stagger(2, 1))
	end)
end)

describe("MotionTokens corner paths", function()
	it("staggers the two axes so the path is never a straight diagonal", function()
		-- Carbon: elements move along the grid, never diagonally. Two axes starting
		-- together IS a diagonal, so exactly one leg must be delayed.
		local p = Tokens.cornerPath(300, 100)
		assert.is_true(p.x.delay ~= p.y.delay)
	end)

	it("leads with the longer leg", function()
		local wide = Tokens.cornerPath(400, 50)
		assert.are.equal(0, wide.x.delay)
		assert.is_true(wide.y.delay > 0)

		local tall = Tokens.cornerPath(50, 400)
		assert.are.equal(0, tall.y.delay)
		assert.is_true(tall.x.delay > 0)
	end)

	it("overlaps the legs, so the corner is rounded rather than square", function()
		-- A square corner means the second leg starts only once the first has
		-- finished. Carbon wants them to overlap.
		local p = Tokens.cornerPath(400, 200)
		assert.is_true(p.y.delay < p.x.duration)
	end)

	it("reports a total that covers both legs", function()
		local p = Tokens.cornerPath(300, 120)
		assert.is_true(p.total >= p.x.delay + p.x.duration)
		assert.is_true(p.total >= p.y.delay + p.y.duration)
	end)
end)
